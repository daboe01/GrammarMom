Hier ist die überarbeitete und korrigierte Version der `README.md`, die exakt auf den aktuellen Zustand Ihres Objective-J-Frontends und Mojolicious-Backends angepasst ist:

```markdown
# AI-Powered Writing Assistant

A web-based, desktop-class text editor and proofreading suite. The application analyzes narrative text paragraph-by-paragraph, highlights errors (spelling, grammar, clarity, and style) with visual overlays, and allows users to apply suggested corrections with a single click.

This project is built using a decoupled client-server architecture:
*   **Frontend**: A desktop-style rich-text UI built on **Cappuccino (Objective-J)**.
*   **Backend**: A lightweight asynchronous API gateway built on **Mojolicious::Lite (Perl)**.

---
<img width="1011" height="837" alt="Bildschirmfoto 2026-05-23 um 19 35 44" src="https://github.com/user-attachments/assets/57864753-bbd3-4ac8-8c76-0979b2eb6f8b" />

## Key Features

*   **Multilingual Analysis**: Real-time language switching (English, German, French) utilizing localized LLM system instructions rendered dynamically via backend templates.
*   **Flexible Provider Integration**: Support for multiple LLM providers (Ollama, Groq API, Google Gemini, and OpenRouter) configurable directly inside the application's settings panel.
*   **Context-Aware Highlighting**: Highlights text segments based on four distinct categories:
    *   🔴 **Spelling**: Typos and spelling mistakes.
    *   🔵 **Grammar**: Syntax issues, tense issues, and punctuation.
    *   🟢 **Clarity**: Passive voice, overly wordy sentences, or confusing phrasing.
    *   🟣 **Style**: Tone improvements and formal adjustments.
*   **Robust String Matching**: Instead of relying on LLM character count offsets (which are often inaccurate), the Perl backend programmatically computes exact offsets using robust substring searches (`index`).
*   **Dynamic Range Shifting**: Applying a correction dynamically shifts the offsets of all remaining alerts in the paragraph, preventing highlight misalignment during active editing.
*   **Session Portability**: Import and export your current document and analyzed corrections in a single unified JSON structure.

---

## Architecture Overview

```text
 ┌────────────────────────┐       POST /DBB/analyze_paragraph       ┌─────────────────────────┐
 │                        │  ───────────────────────────────────>  │                         │
 │  Cappuccino Frontend   │         (Per-Paragraph Payload)        │   Mojolicious Backend   │
 │     (Objective-J)      │  <───────────────────────────────────  │         (Perl)          │
 │                        │        JSON Array of Local Alerts      │                         │
 └────────────────────────┘                                        └────────────┬────────────┘
                                                                                │
                                                                                │  POST API Call
                                                                                ▼
                                                                   ┌─────────────────────────┐
                                                                   │       LLM Service       │
                                                                   │ (Ollama/Groq/Gemini/OR) │
                                                                   └─────────────────────────┘
```

---

## Tech Stack

*   **Frontend**: Objective-J, Cappuccino SDK (AppKit & Foundation ports for the web)
*   **Backend**: Perl 5, Mojolicious::Lite, Mojo::UserAgent
*   **Integration**: JSON REST API

---

## Getting Started

### Prerequisites

*   **Frontend**: A local web server to serve the static Cappuccino assets (e.g., Python's `http.server` or Apache/Nginx).
*   **Backend**: Perl 5 with Mojolicious installed.

### Installation

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/your-username/ai-writing-assistant.git
    cd ai-writing-assistant
    ```

2.  **Install Perl dependencies**:
    ```bash
    cpanm Mojolicious
    ```

3.  **Start the Backend**:
    Run the server in development mode using Morbo:
    ```bash
    morbo app.pl
    ```
    *Note: The backend is preconfigured to bind to port `3001` via Hypnotoad settings.*

4.  **Run the Frontend**:
    Serve your frontend directory and open it in your browser (e.g., `http://localhost:3000/index.html`). 
    
5.  **Configure API Keys**:
    Click on **AI Assistant > Settings...** in the application menu bar to select your provider (Ollama, Groq, Gemini, or OpenRouter) and enter your API credentials. These settings are stored locally in your browser session via `CPUserDefaults`.

---

## API Specification

### Paragraph Analysis Endpoint

*   **Route**: `POST /DBB/analyze_paragraph`
*   **Headers**: `Content-Type: application/json`
*   **Request Payload**:
    ```json
    {
      "text": "Red underlines mean that Grammarly has spotted a mistake in your writing. You'll see one if you mispell something.",
      "paragraph_index": 0,
      "lang_code": "en",
      "service_type": "groq",
      "endpoint": "",
      "model": "llama3-8b-8192",
      "api_key": "gsk_..."
    }
    ```
*   **Response Payload**:
    ```json
    {
      "paragraph_index": 0,
      "text": "Red underlines mean that Grammarly has spotted a mistake in your writing. You'll see one if you mispell something.",
      "alerts": [
        {
          "id": "alert_0_0",
          "category": "spelling",
          "title": "Spelling Correction",
          "original_text": "mispell",
          "suggested_text": "misspell",
          "offset": 92,
          "length": 7,
          "explanation": "The word 'mispell' is misspelled. The correct spelling is 'misspell'."
        }
      ]
    }
    ```

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
```
