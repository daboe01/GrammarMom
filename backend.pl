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

my $ua = Mojo::UserAgent->new(request_timeout => 0, inactivity_timeout => 0, connect_timeout => 0);
$ua->max_connections(0);

# =========================================================
# ROUTE: Analyze a Single Paragraph via Ollama
# =========================================================
post '/DBB/analyze_paragraph' => sub {
    my $c = shift;

    my $payload   = $c->req->json;
    my $p_text    = $payload->{text} // '';
    my $p_idx     = $payload->{paragraph_index} // 0;
    my $run_id    = $payload->{run_id} // 48;
    my $endpoint  = $payload->{ollama_endpoint} // 'http://localhost:11434/api/generate';
    my $model     = $payload->{ollama_model} // 'gemma4:e4b';

    $run_id = 48 unless $run_id =~ /^(48|49)$/;

    unless ($p_text) {
        return $c->render(json => { paragraph_index => $p_idx, text => '', alerts => [] });
    }

    $c->render_later;

    my $clean_p_text = $p_text;
    $clean_p_text =~ s/^\s+|\s+$//g; # trim

    # Load appropriate prompt from __DATA__ section
    # my $prompt_template = Mojo::Loader::data_section('main', $run_id == 49 ? 'german_prompt' : 'english_prompt') // '';
    my $prompt_template = $c->render_to_string($run_id == 49 ? 'german_prompt' : 'english_prompt');
    my $full_prompt = $prompt_template;
    $full_prompt =~ s/__INPUT__/$clean_p_text/g;

    my $json_payload = {
        model   => $model,
        prompt  => $full_prompt,
        stream  => Mojo::JSON->false,
        options => {
            temperature => 0,
            num_ctx     => 40960
        }
    };

    $ua->post_p($endpoint => json => $json_payload)
    ->then(sub {
        my $tx = shift;
        my $raw_alerts = [];

        if ($tx->result && $tx->result->is_success) {
            my $response_text = $tx->result->json->{response} // '';
            warn $response_text;
            # Remove Markdown enclosures if present
            $response_text =~ s/^```(?:json)?//i;
            $response_text =~ s/```$//;
            $response_text =~ s/^\s+|\s+$//g;

            $raw_alerts = eval { Mojo::JSON::from_json($response_text) } // [];
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
        $c->app->log->warn("Ollama processing failed for paragraph $p_idx: $err");
        $c->render(json => {
            paragraph_index => $p_idx,
            text            => $clean_p_text,
            alerts          => []
        });
    });
};

app->config(hypnotoad => {listen => ['http://*:3001'], workers => 3, heartbeat_timeout=>1200, inactivity_timeout=> 1200});
app->start;

__DATA__

@@ german_prompt.html.ep
Sie sind ein kontextsensitiver Korrektur- und Lektoratsassistent.
Analysieren Sie den bereitgestellten Textabschnitt und geben Sie eine JSON-Liste der identifizierten Probleme zurück.

Analysieren Sie den Text auf vier Kategorien:
1. „spelling“: Tippfehler, Rechtschreibfehler und häufige Falschschreibungen.
2. „grammar“: Subjekt-Verb-Kongruenz, Zeichensetzungsfehler, Syntaxfehler, unpassende Tempuswechsel.
3. „clarity“: Zu verschachtelte Sätze, Passivkonstruktionen, unklare Strukturen.
4. „style“: Tonfall-Optimierung, Anpassung an formelleres Vokabular oder Verstöße gegen Stilrichtlinien.

WICHTIGE ANWEISUNGEN:
- Das Feld "original_text" muss exakt dem fehlerhaften Wort oder Satzteil aus dem bereitgestellten Text entsprechen.
- Geben Sie AUSSCHLIESSLICH gültiges, reines JSON aus, das ein flaches Array von Objekten gemäß dem unten stehenden Schema enthält.
- Verwenden Sie keine Markdown-Code-Blöcke (wie ```json) und fügen Sie keinen zusätzlichen Text vor oder nach dem JSON-Objekt an.

JSON-Schema für das Ausgabeformat:
[
  {
    "category": "spelling" | "grammar" | "clarity" | "style",
    "title": "Kurze Beschreibung der Kategorie",
    "original_text": "exakter_originaler_text_aus_dem_dokument",
    "suggested_text": "vorgeschlagener_ersatztext",
    "explanation": "Kurze Erklärung, warum diese Korrektur empfohlen wird."
  }
]

Hier ist dein Text:
__INPUT__

@@ english_prompt.html.ep
You are a context-aware proofreading and copy-editing assistant.
Analyze the provided text paragraph and return a JSON list of identified issues. 

Analyze for four categories:
1. "spelling": Typos, orthography errors, and common misspellings.
2. "grammar": Subject-verb agreement, misuse of punctuation, syntax errors, tense inconsistencies.
3. "clarity": Wordy sentences, passive voice, confusing structures.
4. "style": Tone improvements, formal vocabulary adjustments, or style-guide violations.

CRITICAL INSTRUCTIONS:
- The "original_text" field must match the exact incorrect word or phrase from the provided paragraph text.
- Output ONLY valid, raw JSON containing a flat array of objects matching the schema below. 
- Do not output markdown code blocks (such as ```json) or trailing conversational text.

JSON Schema Output format:
[
  {
    "category": "spelling" | "grammar" | "clarity" | "style",
    "title": "Short category description",
    "original_text": "exact_original_text_from_the_document",
    "suggested_text": "proposed_replacement",
    "explanation": "Brief context explaining why this correction is recommended."
  }
]

Here is your text:
__INPUT__
