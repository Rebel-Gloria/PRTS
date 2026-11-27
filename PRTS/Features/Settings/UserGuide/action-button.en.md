# User Guide

PRTS uses your iPhone camera to detect obstacles ahead, describe your surroundings, answer questions, read text aloud, and announce live movement.

## How to use

- **Start guidance**: Tap Start at the bottom of the screen, or press the Action button once set up. You can also ask Siri or use Back Tap to run Start PRTS, or double-tap with two fingers in VoiceOver.
- **Stop guidance**: Touch and hold the main button at the bottom for 1 second. When Tap to stop is on, or when the app detects AssistiveTouch or Switch Control, tap the main button to stop. If AssistiveTouch is not detected, turn on Tap to stop in Settings. With VoiceOver, double-tap with two fingers, or select the main button and double-tap.
- **Describe the scene**: While the camera is on, briefly press either volume button for a short description of what's ahead.
- **Ask a question**: Press and hold either volume button for half a second, speak after the tone, then release to send. The first time you ask, allow microphone and speech recognition access.
- **Live captions**: Quickly press a volume button three times to hear a brief summary of your surroundings followed by ongoing movement, and press once to stop. Live captions require Allow cloud processing, a saved Qwen API key, and an internet connection.
- **Read text**: Hold three fingers on the screen for about a second, then keep your iPhone steady after the prompt to capture and hear text on signs, papers, or objects. With VoiceOver, select the main button, swipe up or down to choose Read text, then double-tap. Hold three fingers again, tap the main button, or double-tap with two fingers in VoiceOver to exit.

## Button tips

- To launch with the Action button, go to iPhone Settings > Action Button, choose Shortcut, then select Start PRTS. You can also choose Start PRTS in Settings > Accessibility > Touch > Back Tap.
- On iOS 17.2 or later, while the camera is on, the volume buttons take photos instead of changing the volume. To keep them for volume, go to Settings > Interaction in PRTS and turn off Volume button shortcut, then use the Describe photo button in the center of the screen: tap to describe, hold for half a second to ask, or tap three times for live captions. With VoiceOver, swipe up or down on that button to choose Start voice question or Send voice question. On iOS 17.0 or 17.1, use the on-screen Describe photo button instead.

## Settings

- **Intelligence**: Choose On device or an online service for Describe scene, Ask a question, and Read text. Read text also offers Apple Vision and falls back to on-device reading when an online service isn't available; Live captions always use Qwen. Online services require Allow cloud processing and a saved API key. Turning off Allow cloud processing blocks new cloud operations, while active requests and live captions continue. With On device, photos and speech stay on your iPhone; cloud questions may also use Apple's speech service.
- **Interaction**: Turn Low vision mode, Tap to stop, Volume button shortcut, Three-finger text reading, or No camera preview on or off; models with LiDAR also offer Show scan mesh. Low vision mode keeps the camera view and smart features active while pausing depth sensing and guidance cues.
- **Language and Speech**: Turn Voice announcements on or off, adjust Speech rate, or turn off Follow system language to choose a Speech language. Turning off Voice announcements silences status and guidance speech, while descriptions, answers, live captions, and text you request are still read aloud.

## Important

- PRTS is an aid and doesn't replace a white cane or a guide dog.
- Obstacle guidance requires a Pro model with LiDAR and can't detect steps or drop-offs yet. Models without LiDAR don't treat estimated depth as real measurements and won't give guidance cues, though scene descriptions, questions, live captions, and text reading still work.
- Two taps when you start mean only that the camera is on, not that the way ahead has been checked or is clear. PRTS stays quiet at first until it measures what's ahead, and silence never means the path is clear. If you stop and start again, return from reading text, or turn off Low vision mode, wait for a new cue before moving.
- If your iPhone can't measure the ground in view, it won't say "Clear ahead" or give ordinary obstacle or turn cues. Only when the phone points ahead and a very close measured obstacle fills almost the entire view will it say "Obstacle close."
- If new depth measurements briefly drop out, your iPhone can briefly keep guiding only within the area it just measured, for up to about 2 seconds. If you move past that measured area and guidance still hasn't recovered, it vibrates and says "Can't see clearly" once.
- Guidance speech and vibration pause while PRTS describes a scene, answers a question, or shows Settings or this guide. With live captions, guidance speech pauses while vibration cues continue. While reading text or using Low vision mode, PRTS stops checking for obstacles.
- AI descriptions, answers, and text reading can make mistakes. Use your cane along with guidance cues to confirm it's safe before moving ahead.

You can open this guide again anytime from User guide at the bottom of Settings.
