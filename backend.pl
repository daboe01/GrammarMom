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
# ROUTE: Analyze a Single Paragraph via Ollama or Groq API
# =========================================================
post '/DBB/analyze_paragraph' => sub {
    my $c = shift;

    my $payload      = $c->req->json;
    my $p_text       = $payload->{text} // '';
    my $p_idx        = $payload->{paragraph_index} // 0;
    my $lang_code    = $payload->{lang_code} // 'en';
    my $service_type = $payload->{service_type} // 'ollama';
    my $endpoint     = $payload->{ollama_endpoint} // 'http://localhost:11434/api/generate';
    my $model        = $payload->{ollama_model} // 'gemma4:e4b';
    my $groq_api_key = $payload->{groq_api_key} // '';

    # Safety validation of language codes
    $lang_code = 'en' unless $lang_code =~ /^(en|de|fr)$/;

    unless ($p_text) {
        return $c->render(json => { paragraph_index => $p_idx, text => '', alerts => [] });
    }

    my $clean_p_text = $p_text;
    $clean_p_text =~ s/^\s+|\s+$//g; # trim

    # Ignore paragraphs containing only a few words (e.g. headings with 4 or fewer words)
    my @words = split /\s+/, $clean_p_text;
    if (scalar @words <= 4) {
        return $c->render(json => {
            paragraph_index => $p_idx,
            text            => $clean_p_text,
            alerts          => []
        });
    }

    $c->render_later;

    # Load appropriate template via native Mojolicious rendering system
    my $template_name = 'english_prompt';
    if ($lang_code eq 'de') {
        $template_name = 'german_prompt';
    } elsif ($lang_code eq 'fr') {
        $template_name = 'french_prompt';
    }

    my $full_prompt = $c->render_to_string($template_name, text => $clean_p_text);

    my $req_url;
    my $req_headers = { 'Content-Type' => 'application/json' };
    my $req_payload;

    if ($service_type eq 'groq') {
        $req_url = 'https://api.groq.com/openai/v1/chat/completions';
        $req_headers->{'Authorization'} = "Bearer $groq_api_key";
        $req_payload = {
            model    => $model,
            messages => [
                {
                    role    => 'user',
                    content => $full_prompt
                }
            ],
            temperature => 0,
            max_completion_tokens => 8192,
            top_p => 1,
            stream => Mojo::JSON->false
        };
    } else {
        $req_url = $endpoint;
        $req_payload = {
            model   => $model,
            prompt  => $full_prompt,
            stream  => Mojo::JSON->false,
            options => {
                temperature => 0,
                num_ctx     => 40000
            }
        };
    }

    $ua->post_p($req_url => $req_headers => json => $req_payload)
    ->then(sub {
        my $tx = shift;
        my $raw_alerts = [];

        if ($tx->result && $tx->result->is_success) {
            my $response_text = '';
            if ($service_type eq 'groq') {
                $response_text = $tx->result->json->{choices}[0]{message}{content} // '';
            } else {
                $response_text = $tx->result->json->{response} // '';
            }
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
        $c->app->log->warn("AI processing failed for paragraph $p_idx: $err");
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
<%= $text %>

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
<%= $text %>

@@ french_prompt.html.ep
Vous êtes un assistant de relecture et de correction de texte sensible au contexte.
Analysez le paragraphe fourni et retournez une liste JSON des problèmes identifiés.

Analysez le texte selon quatre catégories :
1. "spelling" : Fautes de frappe, erreurs d'orthographe et mots mal orthographiés.
2. "grammar" : Accord sujet-verbe, mauvaise ponctuation, erreurs de syntaxe, incohérences de temps.
3. "clarity" : Phrases trop longues, voix passive, structures confuses.
4. "style" : Améliorations de ton, ajustements de vocabulaire formel ou violations des guides de style.

CONSIGNES CRITIQUES :
- Le champ "original_text" doit correspondre exactement au mot ou à la phrase incorrecte du paragraphe fourni.
- Fournissez UNIQUEMENT du JSON brut et valide contenant un tableau plat d'objets conforme au schéma ci-dessous.
- Ne générez pas de blocs de code Markdown (comme ```json) ni de texte conversationnel supplémentaire.

Format de schéma JSON de sortie :
[
  {
    "category": "spelling" | "grammar" | "clarity" | "style",
    "title": "Brève description de la catégorie",
    "original_text": "texte_original_exact_provenant_du_document",
    "suggested_text": "proposition_de_remplacement",
    "explanation": "Brève explication du contexte justifiant cette correction."
  }
]

Voici votre texte :
<%= $text %>
