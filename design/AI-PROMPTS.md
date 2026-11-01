# AI image prompts for Rimshot

Two self-contained briefs. Paste either one, whole, into an image generator (ChatGPT, Gemini, Midjourney, Ideogram, Recraft, Flux).

---

## Brief 1: App icon

```
I need an app icon for a Mac app. Here's everything about it.

THE PRODUCT
Rimshot is a free, open-source macOS menu bar app that brings back Apple's Touch Bar, but on the trackpad instead of the keyboard. You rest one finger on the very top edge of your MacBook's trackpad, and a slim row of buttons appears at the bottom of your screen: esc, brightness, keyboard light, Mission Control, screenshot, play/pause, volume and mute. You slide your finger left or right to pick a button. Each time you cross into a new button you feel a tiny haptic tick through the trackpad. You lift your finger to press it. If you hold still on a button, it "charges up": the haptic ticks speed up while a glow grows from the centre of the button outward, then it fires by itself. The name "Rimshot" comes from the trackpad's rim (its edge), and it's also the drum hit where the stick strikes the rim.

WHO IT'S FOR
Mac power users and designers who miss the Touch Bar, and MacBook Air owners who never had one. The audience has taste: they use apps like Raycast, CleanShot X, Things and Linear.

BRAND
- Personality: precise, calm, a little witty, premium but not flashy. It's a tiny, native, well-made utility (540 KB, no Electron).
- Colours: warm off-white #FAF5EC, near-black #0B0B0B, and one accent, electric blue #1A6BFF. In the app, blue means "the selected button".
- The website uses huge, tightly spaced bold sans-serif type, beige and black sections, and a pixel-art logo: a square outline made of 8x8 pixels whose top row is blue.

WHAT I WANT
A macOS app icon in Apple's current style:
- 1024x1024 px, the macOS rounded-square ("squircle") shape, with the standard padding so it sits correctly in the Dock next to Apple's own icons.
- One single, simple idea, readable at 32 px.
- Flat or very subtly dimensional. No glossy plastic, no neon glow, no busy gradients.
- Use only the brand colours above, plus at most one neutral grey.
- No text, unless the concept is a keycap labelled "esc".
- No Apple logo and no other logos.

Please make one icon for each of these concepts:
1. PIXEL RIM: pure black background, a centred square outline built from chunky 8x8 pixels, the top row electric blue, the other three sides off-white. Crisp pixel edges.
2. THE CHARGE: near-black background, one wide rounded-rectangle button in electric blue, with three nested rounded rectangles of translucent white inside it, shrinking toward the centre, like a glow growing outward.
3. KEYCAP ESC: dark graphite background, one realistic soft-grey aluminium keycap in the centre labelled "esc" in a clean San Francisco-style font, with a subtle bottom edge and a soft shadow. A wink at the escape key the Touch Bar took away.
4. THE RIM: dark graphite background, the outline of a trackpad with one bright off-white line along its top edge and a small electric-blue dot where a fingertip would touch.

AVOID
Gradient backgrounds, gloss, sparkles, emoji or cartoon style, clutter, multiple objects, drop shadows that look cheap, the Apple logo, watermarks, extra text.
```

Midjourney users: add `--ar 1:1 --style raw --v 7` and put the AVOID list after `--no`.

---

## Brief 2: Hero image for the website's opening screen

```
I need a hero image for the opening screen of a product website. Here's everything about it.

THE PRODUCT
Rimshot is a free, open-source macOS app that brings back Apple's Touch Bar, but on the trackpad. You rest one finger on the very top edge of your MacBook's trackpad and a slim row of buttons (esc, brightness, keyboard light, Mission Control, screenshot, play/pause, volume, mute) appears at the bottom of your screen. You slide to pick a button, feeling a tiny haptic tick on each one, and lift to press. The whole idea is "the Touch Bar is back, and you never have to look down at your keyboard."

THE WEBSITE
- Style: editorial and restrained, inspired by high-end design studio portfolios. It has a warm off-white background #FAF5EC, black sections, one accent colour (electric blue #1A6BFF), huge tightly spaced bold sans-serif headlines, and lots of empty space.
- The headline "The Touch Bar is Back" sits above this image.
- The real, animated Touch Bar interface is added on top of the image in code, so the image itself must NOT contain any interface, buttons or readable text.

WHAT I WANT
A premium, editorial product photograph:
- A perfect top-down overhead view of an open silver MacBook Pro lying on a warm off-white paper or linen surface that matches #FAF5EC.
- The keyboard and the large trackpad are clearly visible and centred. The screen is tilted away and runs out of frame at the top.
- One relaxed, natural-looking hand. Only the index finger rests lightly on the very top edge of the trackpad, as if about to slide sideways. Exactly five fingers, anatomically correct.
- A thin, soft electric-blue line of light (#1A6BFF) glows along the trackpad's top edge, strongest right under the fingertip. That's the only colour accent in the image.
- Calm, soft daylight from the left with gentle, natural shadows.
- Generous empty space around the laptop, so headline text can sit above it.
- Muted, warm, minimal, like Apple product photography crossed with an art-book photo.
- Sharp focus on the fingertip and the trackpad edge.
- Formats: a 16:9 landscape version for desktop and a 4:5 portrait version for phones.

ALSO MAKE (optional)
A three-quarter view from slightly above and behind the user's shoulder: the same open laptop on the same warm desk, the index finger on the trackpad's top edge, and the screen showing a calm, softly blurred dark desktop with a clean, empty strip along the bottom where the Touch Bar will be overlaid.

AVOID
Extra or deformed fingers, more than one hand, faces, the Apple logo or any logos, readable text, any on-screen interface, cluttered desks, coffee cups, plants, phones, dramatic or neon lighting, purple, gradient backgrounds, a stock-photo look.
```

Midjourney users: add `--ar 16:9 --style raw --v 7` (or `--ar 4:5` for the phone version) and put the AVOID list after `--no`.
