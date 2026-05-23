#!/usr/local/ActivePerl-5.14/site/bin/morbo

# HPO Backend 08.03.2017 by Daniel Boehringer

use Mojolicious::Lite;
use Mojolicious::Plugin::Database;
use SQL::Abstract;
use SQL::Abstract::More;
use Data::Dumper;
use Mojo::UserAgent;
use Apache::Session::File;
use Encode;
use Mojo::JSON qw(decode_json encode_json);
use DBIx::Connector;
use POSIX qw(strftime);

no warnings 'uninitialized';

$ENV{MOJO_INACTIVITY_TIMEOUT} = 600;

# turn browser cache off
hook after_dispatch => sub {
    my $tx = shift;
    my $e  = Mojo::Date->new(time - 100);
    $tx->res->headers->header(Expires => $e);
    $tx->res->headers->header('X-ARGOS-Routing' => '3026');
};

# Allow ENV override, fallback to localhost
my $VECTORSTORE_BASE_URL = $ENV{VECTORSTORE_URL} // 'http://localhost:3000';

# Disable Keep-Alive caching for massive parallel requests
my $ua = Mojo::UserAgent->new(request_timeout => 0, inactivity_timeout => 0, connect_timeout => 0);
$ua->max_connections(0);

# =========================================================
# ROUTE: Analyze Text Paragraph-by-Paragraph
# =========================================================
post '/DBB/analyze_text' => sub {
    my $c = shift;

    my $payload   = $c->req->json;
    my $full_text = $payload->{text} // '';
    my $run_id    = $payload->{run_id} // 48;

    # Basic sanitation to ensure only valid run IDs are processed (48 or 49)
    $run_id = 48 unless $run_id =~ /^(48|49)$/;

    unless ($full_text) {
        return $c->render(json => { error => "Missing 'text' parameter in body." }, status => 400);
    }

    # Split document by paragraph blocks
    my @raw_paragraphs = split(/\n\n+/, $full_text);
    my @promises;
    my $p_idx = 0;

    my $url_llm = "$VECTORSTORE_BASE_URL/LLM/run_stateless/$run_id";

    $c->render_later;

    for my $p_text (@raw_paragraphs) {
        next if $p_text =~ /^\s*$/;

        my $current_p_idx = $p_idx;
        my $clean_p_text = $p_text;
        $clean_p_text =~ s/^\s+|\s+$//g; # trim
        warn $clean_p_text;

        my $promise = $ua->post_p($url_llm => { Accept => '*/*' } => encode('UTF-8', $clean_p_text))
        ->then(sub {
            my $tx = shift;
            my $raw_alerts = [];

            if ($tx->result && $tx->result->is_success) {
                my $body = $tx->result->body;
                $body =~ s/^```(?:json)?//i;
                $body =~ s/```$//;
                $body =~ s/^\s+|\s+$//g;
                warn $body;

                $raw_alerts = eval { decode_json($body) } // [];
            }

            my $processed_alerts = [];
            my $id_counter = 0;

            # Dynamische Lokalisierung des Texts im Absatz
            foreach my $alert (@$raw_alerts) {
                my $orig = $alert->{original_text};
                next unless defined $orig && $orig ne '';

                # Suche nach dem exakten Substring im Absatz
                my $offset = index($clean_p_text, $orig);

                # Falls nicht gefunden, versuchen wir eine Case-Insensitive Suche als Fallback
                if ($offset == -1) {
                    $offset = index(lc($clean_p_text), lc($orig));
                }

                # Wenn der Text gefunden wurde, berechnen wir die Positionen
                if ($offset != -1) {
                    $alert->{offset} = $offset;
                    $alert->{length} = length($orig);
                    $alert->{id}     = "alert_" . $current_p_idx . "_" . $id_counter++;
                    push @$processed_alerts, $alert;
                } else {
                    $c->app->log->warn("Could not locate string '$orig' in paragraph $current_p_idx");
                }
            }

            return {
                paragraph_index => $current_p_idx,
                text            => $clean_p_text,
                alerts          => $processed_alerts
            };
        })
        ->catch(sub {
            my $err = shift;
            $c->app->log->warn("LLM processing failed for paragraph $current_p_idx: $err");
            return {
                paragraph_index => $current_p_idx,
                text            => $clean_p_text,
                alerts          => []
            };
        });

        push @promises, $promise;
        $p_idx++;
    }

    if (!@promises) {
        return $c->render(json => { paragraphs => [] });
    }

    Mojo::Promise->all(@promises)->then(sub {
        my @results = map { $_->[0] } @_;
        
        # Sort back to original paragraph order
        @results = sort { $a->{paragraph_index} <=> $b->{paragraph_index} } @results;

        $c->render(json => { paragraphs => \@results });
    })->catch(sub {
        my $err = shift;
        $c->app->log->error("Text analysis orchestration failed: $err");
        $c->render(json => { error => "Analysis failed", details => "$err" }, status => 500);
    });
};

###################################################################
# main()

app->config(hypnotoad => {listen => ['http://*:3001'], workers => 3, heartbeat_timeout=>1200, inactivity_timeout=> 1200});
app->start;
