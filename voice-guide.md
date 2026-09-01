# XSIGHT Kiosk — Voice Guide Script

Recording script for the kiosk's spoken guidance. Every line below is final copy:
paste it into ElevenLabs, generate, and save as the given filename.

Output as **mono MP3** into `assets/voice/en/` and `assets/voice/tl/`, and
declare each folder in `pubspec.yaml` under `flutter: assets:`. The shipped
English set is 44.1 kHz / 128 kbps; sample rate is not critical, mono is.

**Status:** 39 of the 47 English clips are recorded and wired. The eight still
missing — `err_sensor`, `err_temp`, `err_module`, `err_server`, `emergency`,
`session_saved`, `session_end`, `session_cleared` — already have working
triggers and stay silent until their files exist, so recording one and dropping
it into `assets/voice/en/` is the whole job. The Tagalog set is not started;
`VoiceGuide.lang` switches to it once `assets/voice/tl/` is populated.

## Voice direction

- Calm, warm, unhurried. A nurse explaining, not an announcement system.
- Slightly slower than conversational. Users are elderly, unwell, or nervous.
- No upward inflection at the end of instructions — they are not questions.
- Same voice for every clip in a language. Never mix voices mid-session.
- Leave ~150 ms of silence at the head and tail of each clip so cues do not clip
  into each other on playback.

## Rule on numbers

These are fixed audio files, so no clip may contain a measured value. Result
clips tell the user the reading is done and send them to the screen, which shows
the numbers. Never record "your heart rate is seventy two".

---

# English — `assets/voice/en/`

## Session start

| File | Plays when | Script |
| --- | --- | --- |
| `welcome.mp3` | Kiosk is idle, waiting for someone | `Welcome to XSIGHT. Press the green OK button to begin.` |
| `welcome_touch.mp3` | Idle, no sensor unit attached | `Welcome to XSIGHT. Touch the large circle to begin.` |
| `disclaimer.mp3` | Disclaimer screen | `XSIGHT is a screening aid. It does not give a diagnosis. A nurse or doctor will review your results.` |
| `menu_open.mp3` | Station menu opens | `Choose a station. Use up and down to move, then press OK.` |

## Station names

Played on their own when the menu highlight moves.

| File | Script |
| --- | --- |
| `station_vitals.mp3` | `Heart rate and oxygen.` |
| `station_temp.mp3` | `Temperature.` |
| `station_lungs.mp3` | `Lung sounds.` |
| `station_xray.mp3` | `Chest x-ray.` |
| `station_summary.mp3` | `Your results.` |
| `station_assistant.mp3` | `Ask a question.` |
| `station_settings.mp3` | `Settings.` |

## Heart rate and oxygen

| File | Plays when | Script |
| --- | --- | --- |
| `vitals_intro.mp3` | Station opens | `Heart rate and oxygen. This takes about thirty seconds.` |
| `vitals_place.mp3` | Waiting for a finger | `Rest your fingertip on the sensor. Keep it still.` |
| `vitals_active.mp3` | Finger detected, reading started | `That's it. Hold still while I take the reading.` |
| `vitals_done.mp3` | Reading finished | `All done. Your heart rate and oxygen are on the screen.` |
| `vitals_cancelled.mp3` | Reading stopped early | `The reading stopped. Press OK to try again.` |

## Temperature

| File | Plays when | Script |
| --- | --- | --- |
| `temp_intro.mp3` | Station opens | `Temperature. This only takes a few seconds.` |
| `temp_place.mp3` | Waiting for the sensor | `Rest your fingertip on the temperature sensor and hold still.` |
| `temp_active.mp3` | Reading started | `Hold it steady.` |
| `temp_done.mp3` | Reading finished | `All done. Your temperature is on the screen.` |
| `temp_high.mp3` | Reading is above normal | `Your temperature is higher than usual. Please mention this to the nurse.` |

## Lung sounds

| File | Plays when | Script |
| --- | --- | --- |
| `lungs_intro.mp3` | Station opens | `Lung sounds. I will listen for ten seconds.` |
| `lungs_place.mp3` | Before recording | `Place the round sensor on your chest, then press OK.` |
| `lungs_breathe.mp3` | Recording starts | `Breathe normally through your mouth.` |
| `lungs_checking.mp3` | Recording ends, analysis runs | `Thank you. I'm checking the recording now.` |
| `lungs_done.mp3` | Result ready | `All done. The result is on the screen for the nurse to review.` |
| `lungs_retry.mp3` | Recording too quiet or too short | `I didn't hear enough. Move the sensor and let's try again.` |

## Chest x-ray

| File | Plays when | Script |
| --- | --- | --- |
| `xray_intro.mp3` | Station opens | `Chest x-ray. You can send a photo from your phone.` |
| `xray_scan.mp3` | Transfer code on screen | `Scan the square code on the screen with your phone camera.` |
| `xray_received.mp3` | Image arrives | `Image received. Thank you.` |
| `xray_reading.mp3` | Analysis running | `I'm reading the image now. This takes a moment.` |
| `xray_done.mp3` | Result ready | `All done. The result is on the screen. This is a screening check, not a diagnosis.` |
| `xray_failed.mp3` | Image could not be read | `I couldn't read that image. Please ask a staff member for help.` |

## Results summary

| File | Plays when | Script |
| --- | --- | --- |
| `summary_none.mp3` | Nothing measured yet | `Nothing has been measured yet. Choose a station to begin.` |
| `summary_partial.mp3` | Some stations left | `You still have stations left. Check the screen to see which ones.` |
| `summary_low.mp3` | Readings in usual range | `Your readings are in the usual range. Please take your printed copy with you.` |
| `summary_moderate.mp3` | Some readings need review | `Some of your readings need a closer look. Please speak to a nurse today.` |
| `summary_high.mp3` | Readings need attention | `Your readings need attention. Please see a nurse straight away.` |
| `summary_disclaimer.mp3` | After any result | `Remember, XSIGHT is a screening aid, not a diagnosis.` |

## Problems and help

| File | Plays when | Script |
| --- | --- | --- |
| `err_sensor.mp3` | Sensor did not respond | `The sensor isn't responding. Please ask a staff member for help.` |
| `err_temp.mp3` | Temperature out of range | `That reading didn't look right. Hold the sensor closer and try again.` |
| `err_module.mp3` | Sensor unit not connected | `The sensor unit isn't connected. Please ask a staff member for help.` |
| `err_server.mp3` | Server unreachable | `I can't reach the server right now. Please ask a staff member for help.` |
| `emergency.mp3` | Readings need immediate attention | `Please tell a nurse now. Do not wait.` |

## Session end

| File | Plays when | Script |
| --- | --- | --- |
| `session_saved.mp3` | Staff saved to a patient record | `Reading saved.` |
| `session_end.mp3` | Session closes or times out | `Your session is finished. Thank you for using XSIGHT.` |
| `session_cleared.mp3` | Kiosk resets for the next person | `Ready for the next person.` |

---

# Tagalog — `assets/voice/tl/`

Same filenames, same folder structure, `tl/` instead of `en/`. Generate with a
Filipino voice — do not run the English voice on Tagalog text.

## Session start

| File | Script |
| --- | --- |
| `welcome.mp3` | `Magandang araw po. Pindutin ang OK button para magsimula.` |
| `welcome_touch.mp3` | `Magandang araw po. Pindutin ang malaking bilog para magsimula.` |
| `disclaimer.mp3` | `Ang XSIGHT ay pantulong lamang sa screening. Hindi po ito diagnosis. Ang nurse o doktor ang magrerepaso ng resulta.` |
| `menu_open.mp3` | `Pumili po ng istasyon. Gamitin ang up at down, pagkatapos pindutin ang OK.` |

## Station names

| File | Script |
| --- | --- |
| `station_vitals.mp3` | `Heart rate at oxygen.` |
| `station_temp.mp3` | `Temperatura.` |
| `station_lungs.mp3` | `Tunog ng baga.` |
| `station_xray.mp3` | `Chest x-ray.` |
| `station_summary.mp3` | `Ang resulta ninyo.` |
| `station_assistant.mp3` | `Magtanong.` |
| `station_settings.mp3` | `Settings.` |

## Heart rate and oxygen

| File | Script |
| --- | --- |
| `vitals_intro.mp3` | `Heart rate at oxygen. Aabutin po ito ng mga tatlumpung segundo.` |
| `vitals_place.mp3` | `Ipatong po ang dulo ng daliri sa sensor. Huwag gumalaw.` |
| `vitals_active.mp3` | `Ayan po. Huwag gumalaw habang kinukuha ang reading.` |
| `vitals_done.mp3` | `Tapos na po. Nasa screen ang heart rate at oxygen ninyo.` |
| `vitals_cancelled.mp3` | `Natigil po ang reading. Pindutin ang OK para subukan muli.` |

## Temperature

| File | Script |
| --- | --- |
| `temp_intro.mp3` | `Temperatura. Ilang segundo lang po ito.` |
| `temp_place.mp3` | `Ilapit po ang sensor sa noo, mga apat na sentimetro ang layo.` |
| `temp_active.mp3` | `Huwag pong iurong. Panatilihing steady.` |
| `temp_done.mp3` | `Tapos na po. Nasa screen ang temperatura ninyo.` |
| `temp_high.mp3` | `Mas mataas po sa normal ang temperatura ninyo. Sabihin po ito sa nurse.` |

## Lung sounds

| File | Script |
| --- | --- |
| `lungs_intro.mp3` | `Tunog ng baga. Makikinig po ako ng sampung segundo.` |
| `lungs_place.mp3` | `Ipatong po ang bilog na sensor sa dibdib, pagkatapos pindutin ang OK.` |
| `lungs_breathe.mp3` | `Huminga po nang normal sa bibig.` |
| `lungs_checking.mp3` | `Salamat po. Tinitingnan na ang recording.` |
| `lungs_done.mp3` | `Tapos na po. Nasa screen ang resulta para sa nurse.` |
| `lungs_retry.mp3` | `Hindi po sapat ang narinig ko. Iusog ang sensor at subukan muli.` |

## Chest x-ray

| File | Script |
| --- | --- |
| `xray_intro.mp3` | `Chest x-ray. Maaari po kayong magpadala ng larawan mula sa telepono.` |
| `xray_scan.mp3` | `I-scan po ang parisukat na code sa screen gamit ang camera ng telepono.` |
| `xray_received.mp3` | `Natanggap na po ang larawan. Salamat.` |
| `xray_reading.mp3` | `Binabasa na po ang larawan. Maghintay lang po ng kaunti.` |
| `xray_done.mp3` | `Tapos na po. Nasa screen ang resulta. Screening check lang po ito, hindi diagnosis.` |
| `xray_failed.mp3` | `Hindi po nabasa ang larawan. Magtanong po sa staff.` |

## Results summary

| File | Script |
| --- | --- |
| `summary_none.mp3` | `Wala pa pong nakuhang measurement. Pumili ng istasyon para magsimula.` |
| `summary_partial.mp3` | `May natitira pa pong istasyon. Tingnan sa screen kung alin.` |
| `summary_low.mp3` | `Normal po ang mga reading ninyo. Dalhin po ang naka-print na kopya.` |
| `summary_moderate.mp3` | `May mga reading pong kailangang tingnan pa. Kausapin po ang nurse ngayon.` |
| `summary_high.mp3` | `Kailangan pong bigyan ng atensyon ang mga reading ninyo. Lapitan po ang nurse agad.` |
| `summary_disclaimer.mp3` | `Tandaan po, ang XSIGHT ay pantulong lamang sa screening, hindi diagnosis.` |

## Problems and help

| File | Script |
| --- | --- |
| `err_sensor.mp3` | `Hindi po tumutugon ang sensor. Magtanong po sa staff.` |
| `err_temp.mp3` | `Mali po ang lumabas na reading. Ilapit ang sensor at subukan muli.` |
| `err_module.mp3` | `Hindi po nakakonekta ang sensor unit. Magtanong po sa staff.` |
| `err_server.mp3` | `Hindi po maabot ang server ngayon. Magtanong po sa staff.` |
| `emergency.mp3` | `Sabihin po sa nurse ngayon. Huwag maghintay.` |

## Session end

| File | Script |
| --- | --- |
| `session_saved.mp3` | `Nai-save na po ang reading.` |
| `session_end.mp3` | `Tapos na po ang session ninyo. Salamat sa paggamit ng XSIGHT.` |
| `session_cleared.mp3` | `Ready na po para sa susunod.` |

---

# Where each clip fires

Trigger points already exist in the code — no new plumbing needed.

| Clip group | File and handler |
| --- | --- |
| Welcome, menu, station names | `kiosk_shell.dart` — `_openMenu`, `_moveFocus`, `_focusModuleFromModule` |
| Station intros, place prompts | `kiosk_shell.dart` — `_openModuleScreen`, `_showSensorPrompt` |
| `vitals_*` | `kiosk_shell.dart` — `_onPulseState` (`WAITING` / `ACTIVE` / `DONE` / `CANCELLED`) |
| `temp_*` | `kiosk_shell.dart` — `_onTempState` (`ACTIVE` / `DONE`); `kiosk_temp_screen.dart` — `_onEsp32Data` |
| `lungs_*` | `kiosk_lung_sound_screen.dart` — `_onHardwareStethState`, `_stop`, `_analyzeEsp32` |
| `xray_*` | `kiosk_xray_screen.dart` — `_onHandoff`, `_analyze` |
| `summary_*` | `kiosk_cdss_screen.dart` — `_triage`, on change only |
| `err_sensor`, `err_temp` | `kiosk_shell.dart` — `_onSensorError` |
| `err_module` | `kiosk_shell.dart` — `_buildLinkWarning` |
| `disclaimer` | `disclaimer_screen.dart` |

# Playback rules

All of these are enforced inside `VoiceGuide.say` (`lib/core/voice/voice_guide.dart`),
not at the call sites. Trigger a cue whenever its state is entered; the player
decides whether it is heard.

- **One clip at a time.** A new cue stops whatever is playing.
- **Paired lines chain.** `sayAll` starts each clip when the one before it ends,
  so `temp_intro` → `temp_place` plays as a sentence rather than the second
  truncating the first. Any newer request abandons a sequence mid-flight.
- **No repeat within ten seconds.** Sensor callbacks are not edge-triggered —
  the serial client notifies per frame — so the same cue arrives in bursts. A
  different cue in between clears the guard at once.
- **Guest mode only** for coaching and results. Staff hear navigation, faults,
  and alarms. A clinician does not need coaching, and the kiosk talking over
  them is noise.
- **Never with a patient record linked.** A reading read aloud names a real
  person in a shared room; the speaker is not a private channel.
- **Muted while the assistant's voice or chat screen is open.** Those screens
  call `VoiceGuide.suspend()`. Guide audio through the kiosk speaker is picked
  up by the microphone and transcribed as though the user had said it —
  `/ws/voice` mutes the mic only around audio it streams itself.
- **Switchable.** Settings → Spoken Guidance carries an on/off switch, a volume
  slider, and a Test button that plays `welcome.mp3`. Both persist.
