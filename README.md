<p align="center"><img src="docs/assets/evanto.png" alt="Evanto app icon" width="96" height="96"></p>

# Evanto

A native Mac assistant that turns a spoken question into live captions and a written answer. Follow a conversation in English or বাংলা, ask about a screenshot, or bring your own notes into the conversation.

**macOS 26+ · Apple silicon · ChatGPT sign-in through Codex**

[Installation guide](docs/installation.md) · [User guide](docs/user-guide.md) · [GitHub releases](https://github.com/sambhuiyan/evanto/releases)

## Your first conversation

1. Open **Evanto → Settings → Sign in with ChatGPT**. Your account supplies the available models.
2. In **Settings → Capture**, choose a display or window and the spoken language. Select **বাংলা (বাংলাদেশ)** for Bangladeshi speech in Bengali script.
3. Choose **Start live**. Turn on **Mac audio** to listen to playback or **Microphone** to listen to someone nearby. You can mute either one mid-conversation.
4. Read the live transcript in the floating panel. With **Auto-answer** enabled, Evanto waits for a pause and answers grouped sentences together. **Answer now** submits the current passage immediately.

## What you can bring into a conversation

| Input | How to use it |
| --- | --- |
| Speech | Read separate captions for Mac playback and the microphone while an answer is on screen. Adjust the pause before answering in Settings. |
| A page on screen | Press **Send screenshot** when the page you want is visible. Each press attaches one still to the question. |
| A CV or notes | Import files in **Reference library**. Evanto draws on each saved reference across chats and selects relevant passages from longer documents. |
| A task on your Mac | Choose **Mac task**, select a working folder, and type the task. Select an app and grant Accessibility if the task also needs the cursor or keyboard. |

### Presenting in a meeting

Start Live, then choose **Entire Screen → Shared Screen** in the meeting’s picker. Some browsers call it **Screen 2**. This display carries the filtered desktop while the answer panel stays on your Mac. Sharing the built-in display directly can expose Evanto. Closing the local preview keeps the shared feed running. [Screen sharing and recording](docs/user-guide.md#share-or-record)

### Where your data goes

The Mac handles audio capture and transcription. Answering a question sends the prompt, relevant transcript and saved reference material to OpenAI through your own Codex session. A screenshot question also sends the selected frame. A typed Mac task can send the contents of files or window images it uses. Imported references persist locally until removed. [Context and storage](docs/user-guide.md#context-and-storage)

## License and acknowledgments

Developed by **Md Adnan Sami Bhuiyan**. Evanto’s original source and documentation are available under the [MIT License](LICENSE).

Evanto bundles the OpenAI Codex CLI for sign-in and model access, whisper.cpp for on-device decoding, and the Bengali.AI Whisper model for Bangla captions. The interface uses DM Sans and DM Serif Text. Each component retains its upstream license. [Codex notices](Packaging/Codex) · [Speech model and engine notices](Packaging/Speech) · [Font licenses](Packaging/Fonts)
