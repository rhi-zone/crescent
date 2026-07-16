# Persona: SillyTavern power user migrating

okay, deep breath. new app, new tab, let's see what this thing is.

---

alright, loading screen. clean-looking. not gonna lie the aesthetic already feels less "hobbyist forum project" and more "someone designed this on purpose." that's either a good sign or a sign it's gonna be locked down and annoying. we'll see.

first screen — some kind of welcome/onboarding thing. i skim it, my eyes are already hunting for the character import button because that's the whole test. i don't care about the mission statement, i care about whether my Aldric card is going to import with his personality intact or whether i'm about to lose four months of prompt tweaking.

there it is. "import character" or "add character" or whatever it's called, top corner. click.

file picker pops up. i navigate to my downloads folder — i've got like six PNGs sitting there that i exported from ST last night specifically for this. grab the one i actually care about testing first, not my favorite favorite, my *second* favorite, because if this breaks something i'd rather find out on him than on the one i actually love.

drag it in. little spinner. and — okay, this is the moment. is it going to read the embedded json correctly or is it going to choke and give me an empty shell with just the picture?

...it loads. thank god. i can see his name populate, avatar shows up correct. i immediately click into his profile to check the actual fields, because "it imported" doesn't mean "it imported *correctly*." i'm checking: is the personality field intact, did description get truncated, did it mangle any of my curly-brace {{char}}/{{user}} macros, is the first message still exactly what i wrote or did some formatting get eaten.

scrolling through... looks right? the macros rendered as raw text in the edit box which is what i want, i don't want them silently converted to something else under the hood without me knowing. good. that's actually a relief because i've seen apps "helpfully" rewrite that stuff and it breaks half your greeting.

now i'm poking at where the character book / lorebook entries would be, because that card had a small lorebook attached — three or four entries about the setting. did it come through? ...i click a tab, find something called "world info" or "lore" or whatever they're branding it. entries are there. keys are there. i check one entry's trigger keys against what i remember setting and it's the same. okay. actually genuinely good.

now the part i'm bracing for: starting an actual chat. click "start chat" or whatever, new conversation opens, i see the character's first message pop in like it should. good, formatting's clean, no stray asterisks or broken markdown.

i type something dumb and short just to test the plumbing, not even in-character yet, basically just "hey" — because i want to see what model it's hitting and how fast it responds before i invest a real message.

waiting... response comes back. i read it. is it in voice? kind of? it's serviceable, not amazing, but that's not necessarily the app's fault, that's model/preset dependent, so i don't panic yet. what i'm actually paying attention to is: did the system prompt assembly respect my character's personality + scenario + my persona description all at once, or is something getting dropped. i can usually tell by whether details from the lorebook show up when relevant. i mention something that should trigger a lore entry keyword on purpose. ...it picks up on it. okay, world info is actually wired in, not just cosmetically imported. that's the real test and it passed.

now, settings. this is where i get precious. i go hunting for the equivalent of the ST "advanced formatting" and sampler panels because i have Opinions — temperature, min-p, rep penalty, the whole context template situation, whether i can edit the actual instruct/story-string templates or whether i'm stuck with presets someone else picked for me.

i find a settings gear. click. there's temperature, top-p... i scroll for min-p specifically because that's my main lever these days and if it's not exposed i'm going to be mildly annoyed. ...it's there. okay good. rep penalty, present. i look for a raw/advanced toggle because half these sliders are useless to me without knowing the exact prompt template being sent — i want to see the actual text going to the model, not just abstracted sliders.

i find something like "view raw prompt" or a debug/preview pane. click it, and there's the actual assembled context — system prompt, character card fields in whatever order, chat history, my message. i read through the order fields get concatenated in because that ordering is exactly the kind of thing that silently changes a character's voice and nobody tells you.

order looks sane, roughly matches what i'd expect from ST's default template. i don't see an obvious way to fully rewrite the story string/instruct template from scratch yet, just toggle between presets, and that's the one thing that makes me go "hm." i make a mental note, not a dealbreaker yet, i just want to know if it's there before i commit to switching my whole workflow over.

i poke a couple more corners — is there a way to set a global user persona so i'm not re-typing my persona description into every card, is there token count visibility so i'm not blind to context overflow, is there any indication of what backend/API it's actually hitting behind the scenes. persona thing, yes, there's a persona manager, decent. token counter, i see a little number ticking near the input box, good, i actually use that constantly in ST to know when i'm about to blow past context.

overall vibe: import worked cleanly including lorebook, chat plumbing respects the card and world info, sampler settings are exposed at the level i actually use, raw prompt is inspectable. the one open question in my head is how deep the template customization goes versus ST where i can rewrite the whole instruct format byte for byte. i'm not going to fully migrate off one card's worth of testing, but i don't feel like i just wasted twenty minutes either — i'm going to bring over three or four more cards and actually run a longer conversation before i decide if this earns a permanent spot next to ST instead of just being a curiosity i checked out once.
