# Translate

Translate text in Tuna with Apple's on-device translation. Installation requires macOS 26 or later
and Tuna 0.96 or later.

## Use it

Start with the text or with the command, whichever comes first to mind:

| First | Then | Third | You get |
| --- | --- | --- | --- |
| some text | **Translate** | — | one translation per language you translate into |
| some text | **Translate To…** | a language | one translation |
| **Translate** | **Translate…** | the text | one translation per language you translate into |
| **Translate to German** | **Translate…** | the text | one translation |

Global search lists **Translate** and one **Translate to …** for each language you translate
into. If the commands are missing, open Tuna Settings → Sources, select the **Translate** source,
and set **In global search** to **All**. Browse into **Translate** to find every other language.
When you start with the command, the text box starts with the clipboard, unless a password
manager marked it concealed.

The source language is detected automatically. When the text is too short to tell for sure,
such as a single word, detection leans towards your own languages. Each translation is a normal text result: copy it, paste it, show it in Large Type, or
translate it again.

If you only need a hotkey for one language or want to add translation to an existing shortcut,
use Apple's **Translate Text** action. You can pass text from Tuna using **Send to Shortcut…**.

## Settings

**Translate into** takes language codes such as `de, en, zh-Hant`. Leave it empty to use your
Mac's preferred languages from System Settings → General → Language & Region.

## Language downloads

Only language pairs already downloaded on your Mac work. A pair that isn't downloaded shows an
item that opens Language & Region; download it under **Translation Languages**. Tuna can't show
Apple's download prompt itself, because that prompt needs a window of its own.

## Privacy

Translation runs on your Mac through Apple's Translation framework. The extension sends nothing
over the network, stores nothing, and writes nothing.

## Limits

- No language override for the source: if detection guesses wrong, there's no way to correct it.
