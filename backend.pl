use Mojolicious::Lite;
use Data::Dumper;
use Mojo::UserAgent;
use Encode;
use Mojo::JSON qw(decode_json encode_json);

no warnings 'uninitialized';

$ENV{MOJO_INACTIVITY_TIMEOUT} = 600;

hook after_dispatch => sub {
    my $tx = shift;
    my $e  = Mojo::Date->new(time - 100);
    $tx->res->headers->header(Expires => $e);
    $tx->res->headers->header('X-ARGOS-Routing' => '3026');
};

my $VECTORSTORE_BASE_URL = $ENV{VECTORSTORE_URL} // 'http://localhost:3000';

my $ua = Mojo::UserAgent->new(request_timeout => 0, inactivity_timeout => 0, connect_timeout => 0);
$ua->max_connections(0);

# =========================================================
# NEW ROUTE: Analyze a Single Paragraph (Progressive)
# =========================================================
post '/DBB/analyze_paragraph' => sub {
    my $c = shift;

    my $payload   = $c->req->json;
    my $p_text    = $payload->{text} // '';
    my $p_idx     = $payload->{paragraph_index} // 0;
    my $run_id    = $payload->{run_id} // 48;

    $run_id = 48 unless $run_id =~ /^(48|49)$/;

    unless ($p_text) {
        return $c->render(json => { paragraph_index => $p_idx, text => '', alerts => [] });
    }

    my $url_llm = "$VECTORSTORE_BASE_URL/LLM/run_stateless/$run_id";

    $c->render_later;

    my $clean_p_text = $p_text;
    $clean_p_text =~ s/^\s+|\s+$//g; # trim

    $ua->post_p($url_llm => { Accept => '*/*' } => encode('UTF-8', $clean_p_text))
    ->then(sub {
        my $tx = shift;
        my $raw_alerts = [];

        if ($tx->result && $tx->result->is_success) {
            my $body = $tx->result->body;
            $body =~ s/^```(?:json)?//i;
            $body =~ s/```$//;
            $body =~ s/^\s+|\s+$//g;

            $raw_alerts = eval { decode_json($body) } // [];
        }

        my $processed_alerts = [];
        my $id_counter = 0;

        foreach my $alert (@$raw_alerts) {
            my $orig = $alert->{original_text};
            next unless defined $orig && $orig ne '';

            my $offset = index($clean_p_text, $orig);
            if ($offset == -1) {
                $offset = index(lc($clean_p_text), lc($orig));
            }

            if ($offset != -1) {
                $alert->{offset} = $offset;
                $alert->{length} = length($orig);
                $alert->{id}     = "alert_" . $p_idx . "_" . $id_counter++;
                push @$processed_alerts, $alert;
            }
        }

        $c->render(json => {
            paragraph_index => $p_idx,
            text            => $clean_p_text,
            alerts          => $processed_alerts
        });
    })
    ->catch(sub {
        my $err = shift;
        $c->app->log->warn("LLM processing failed for paragraph $p_idx: $err");
        $c->render(json => {
            paragraph_index => $p_idx,
            text            => $clean_p_text,
            alerts          => []
        });
    });
};

# =========================================================
# ROUTE: Analyze Text Paragraph-by-Paragraph (Batch fallback)
# =========================================================
post '/DBB/analyze_text' => sub {
    my $c = shift;

    my $payload   = $c->req->json;
    my $full_text = $payload->{text} // '';
    my $run_id    = $payload->{run_id} // 48;

    $run_id = 48 unless $run_id =~ /^(48|49)$/;

    unless ($full_text) {
        return $c->render(json => { error => "Missing 'text' parameter in body." }, status => 400);
    }

    my @raw_paragraphs = split(/\n\n+/, $full_text);
    my @promises;
    my $p_idx = 0;

    my $url_llm = "$VECTORSTORE_BASE_URL/LLM/run_stateless/$run_id";

    $c->render_later;

    for my $p_text (@raw_paragraphs) {
        next if $p_text =~ /^\s*$/;

        my $current_p_idx = $p_idx;
        my $clean_p_text = $p_text;
        $clean_p_text =~ s/^\s+|\s+$//g;

        my $promise = $ua->post_p($url_llm => { Accept => '*/*' } => encode('UTF-8', $clean_p_text))
        ->then(sub {
            my $tx = shift;
            my $raw_alerts = [];

            if ($tx->result && $tx->result->is_success) {
                my $body = $tx->result->body;
                $body =~ s/^```(?:json)?//i;
                $body =~ s/```$//;
                $body =~ s/^\s+|\s+$//g;

                $raw_alerts = eval { decode_json($body) } // [];
            }

            my $processed_alerts = [];
            my $id_counter = 0;

            foreach my $alert (@$raw_alerts) {
                my $orig = $alert->{original_text};
                next unless defined $orig && $orig ne '';

                my $offset = index($clean_p_text, $orig);
                if ($offset == -1) {
                    $offset = index(lc($clean_p_text), lc($orig));
                }

                if ($offset != -1) {
                    $alert->{offset} = $offset;
                    $alert->{length} = length($orig);
                    $alert->{id}     = "alert_" . $current_p_idx . "_" . $id_counter++;
                    push @$processed_alerts, $alert;
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
        @results = sort { $a->{paragraph_index} <=> $b->{paragraph_index} } @results;
        $c->render(json => { paragraphs => \@results });
    })->catch(sub {
        my $err = shift;
        $c->render(json => { error => "Analysis failed", details => "$err" }, status => 500);
    });
};

app->config(hypnotoad => {listen => ['http://*:3001'], workers => 3, heartbeat_timeout=>1200, inactivity_timeout=> 1200});
app->start;
