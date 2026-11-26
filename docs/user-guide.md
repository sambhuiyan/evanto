# Evanto user guide

[Overview](../README.md) · [Installation](installation.md)

Evanto is a native macOS menu-bar assistant. Its bundled OpenAI Codex runtime signs in directly with ChatGPT and calls the models available to that account. Screen capture, transcription, file operations, and cursor movement run on the Mac. All replies appear as text in the workspace and floating answer panel.

## Use the app

1. Open **Evanto.app**. **Settings** shows the connected ChatGPT account and its models. Choose **Sign in with ChatGPT** if you need to sign in. The official Codex runtime opens the browser and manages OAuth. Evanto reuses an existing Codex ChatGPT session automatically. [Codex app server authentication](https://developers.openai.com/codex/app-server/#authentication)
2. Choose **Reference library → Add files** to add a CV, notes, or other reference material. You can also type a question before starting capture.
3. In **Settings → Capture → Shared view**, select the display or app window you plan to share, then choose **Start live**. Allow screen and system-audio capture when macOS asks. Enable microphone access for nearby speech. Reopen Evanto if macOS requests a restart.
4. Use **Microphone** and **Mac audio** to mute the two inputs independently. With **Auto-answer** on, Evanto groups consecutive sentences from each input and shows one written reply when the speaker pauses. Mac playback can prompt a reply even when its transcript has no question mark. **Transcript** shows each input. **Answer now** submits the latest whole passage immediately.
5. **Start live** opens the private answer panel and puts the workspace away. Click **Evanto** in the Dock to bring the normal workspace forward. **Show answer panel** places the panel on the current display, and **Option–Shift–Space** toggles it. Closing the workspace leaves the session running in the menu bar. **Stop live** ends capture.

Interview answers use the most relevant experience in your reference library. For behavioral questions, Evanto writes a complete first-person story with the situation, your actions, the reasoning, and the supported result. If the references lack a real example, it writes a clearly labeled hypothetical.

**Settings → ChatGPT account → Reply speed** defaults to **Fast** for spoken, typed, and screenshot answers. It requests low reasoning when supported and streams the first sentence as it arrives. Mac tasks use your selected reasoning level, which defaults to High. **Use selected reasoning** applies that level to all replies. On supported models you can also choose **Fast with priority**, which uses more of your ChatGPT plan allowance. [Codex speed settings](https://developers.openai.com/codex/speed)

The default **Pause before answering** is three seconds. In **Settings → Capture**, choose five seconds for speakers who pause between the setup and the follow-up, or two seconds for faster replies. The floating panel shows the complete spoken prompt above its answer.

## Work with files and the cursor

Choose **Mac task** beside the message field and type the task. The folder button selects where Evanto can list, read, create, edit, move, and trash items. New text files and edits use UTF-8. The initial working folder is **~/Library/Application Support/Evanto/Workspace**. Selecting a different folder applies to subsequent tasks.

For desktop actions, choose a running app from **Control** and open a window in that app. Enable **Settings → Mac tasks → Cursor & keyboard** when prompted. macOS needs Accessibility for input and Screen & System Audio Recording for window images. **Test cursor and keyboard** checks movement, clicking, and typing in a temporary Evanto window.

Evanto can bring the selected app forward, observe its window, move, click, double-click, right-click, drag, scroll, type, and press shortcuts. The current task shows which tool is running. Use the stop button in the composer or **Stop Current Response or Task** in the menu bar to interrupt it. Heard questions and screenshot answers use the answer-only mode.

## Share or record

**Start live** adds a separate 1080p display named **Shared Screen**. In Brave or Chrome, choose **Present now → Entire Screen** and select the added display. The picker may label it **Screen 2**. Keep working on your MacBook. The added display shows Evanto’s filtered view of your work, without the local answer panel, title bar, or preview controls. Selecting the MacBook display shares its ordinary desktop.

The **Window** tab also offers a borderless **Shared Screen** source. It remains available if macOS cannot create an extra display. The app uses CoreGraphics’ undocumented virtual-display interface for the Entire Screen option. The runtime checks availability when starting a share. [Chromium’s macOS virtual display implementation](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm)

**Share & record → Show local preview** opens an optional preview on your Mac. Closing it keeps the meeting feed running. **Stop share source** removes the virtual display and stops the feed while audio transcription continues. **Stop live** ends both. Bring the work you want to present to the front. Leaving Meet’s own presentation preview in front can repeat the meeting image. [Google Meet presentation help](https://support.google.com/meet/answer/9308856?hl=en)

Click **Send screenshot** on the right side of the floating answer panel to send the current clean frame straight to an image-capable ChatGPT model. Each press sends one still of the selected view and uses your saved references. You can keep sharing, navigate to another page, and press again when you want a new screenshot. The button works while another answer is in progress. The floating panel can switch between the latest screenshot and Mac audio replies. The workspace keeps each response with its question.

For a local video, choose **Share & record → Record Clean MP4**. Choose a destination, then **Finish Recording** when done. The video uses the same filtered display and the enabled audio inputs. Muting a source also mutes it in the video.

Choose how answers appear under **Settings → Screen sharing → Answer panel**. The default **Capture-protected video** uses AVFoundation. The panel can be invisible on some local displays. **Native panel with Clean Share** displays answers in a normal Mac panel. Both panel modes support the **Shared Screen** feed and **Record Clean MP4**, which explicitly exclude Evanto’s windows. Third-party full-display recorders can include the native panel, workspace, or Dock icon. [Apple’s video-layer capture protection](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/preventscapture) · [Apple’s window-sharing setting](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none) · [ScreenCaptureKit content filters](https://developer.apple.com/documentation/screencapturekit/sccontentfilter)

## Context and storage

- Choose **Settings → Capture → Spoken language** for Mac audio and microphone captions. Choose **বাংলা (বাংলাদেশ) · Bangla (Bangladesh)** for Bengali-script captions using the bundled Bengali.AI Whisper model. Other choices use the speech models supported by this Mac. macOS downloads those models on first use. The floating panel shows live captions above the answer. Each enabled input has its own recognizer. The transcript keeps both speakers’ words and applies revisions to the matching audio times. Muting an input or stopping the session lets the recognizer finish the speech already captured. [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- Spoken and typed questions can include recent conversation, enabled speech context, and saved references. Screen sharing, clean recording, and navigating between pages run locally. Only the **Send screenshot** action adds the current shared view to a chat request.
- A typed Mac task sends the file content and selected app window images it needs through the same signed-in Codex connection. The selected app and folder are fixed for that task. The app checks the target window before sending mouse or keyboard input.
- The library accepts PDFs, including scanned pages with readable text, Word documents, PowerPoint and Excel Open XML files, OpenDocument files, RTF, images, and UTF-8 or BOM-marked UTF-16 text such as Markdown, CSV, JSON, and source code. Each import supports up to 32 MB of input and 4 MB of extracted text.
- Extracted text and resized reference images are stored under **~/Library/Application Support/Evanto/References**. Every question includes reference material from every saved file. Long documents contribute excerpts selected for the question. Removing a library entry affects future requests.
- **New chat** clears the in-memory conversation and retains the library. Evanto saves audio and video only when you start an MP4 recording.
