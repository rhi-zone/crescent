# Persona: KoboldAI local inference user

okay, laptop's on the coffee table, browser open. let's see what this thing actually is.

---

alright, landing page. clean. there's a "get started" button. clicking it.

...it wants me to sign up? or is there a local option. scanning... okay there, small text, "use your own model" or something like that. good, that's what i actually want. i don't need their hosted whatever, i've got a 3090 sitting there doing nothing right now.

click that.

now it's asking for a connection — some kind of endpoint field. okay, this is the part that actually matters. i've got koboldcpp running on port 5001 like always. typing `http://localhost:5001` into the field.

hit connect.

...spinner. spinner. come on.

okay it connected, good sign. it's pulling the model name automatically? that's actually nice, saves me typing it in wrong. shows something like "loaded: my-finetune-Q5_K_M.gguf" — yep that's the one i've got loaded in kobold right now. cool, so it's actually talking to my backend and not just pinging it.

now — is there a way to see context length? i want to know if it picked up my context size or if it's going to assume some default and truncate my stuff. hunting around... there's a settings gear somewhere probably. not on this connection screen though. bit annoying, i want to verify the handshake actually got that info before i start dumping a big system prompt into it.

moving on for now, i'll check later.

---

next it wants me to pick a character or load a card. oh nice, drag and drop for a PNG card, that's the standard now right, tavern card format. i've got a folder of these. dragging one in.

...loading... okay, avatar shows up, name shows up, description populated. it parsed the embedded json out of the png metadata correctly, that's not nothing, i've used frontends that mangle this.

is the first message showing? yeah, there's the greeting. looks like it rendered markdown fine, no weird asterisk soup.

alright, chat time.

typing something to test it out, casual, see how it responds pull up the reply.

...generating... little typing indicator, streaming in token by token. good, i hate frontends that just show a blank screen until the whole response is done, feels broken. this feels alive.

response comes in, reads okay. reads like the model, actually, not like it's being mangled by some hidden instruction wrapper. that's the paranoid part of me relaxing a little — a lot of these apps inject their own system prompt structure on top of what you write and it warps the character voice. this one seems to leave it alone, or at least i can't tell that it didn't.

sending a follow up. same thing, streams in, fine.

now the actual test: i want to tweak generation settings. this is where these apps usually fall apart for me — they either hide everything behind "auto" or they give you three sliders and call it a day and i can't get to min-p or a real repetition penalty range or DRY sampling or anything like that.

looking for settings... there's an icon, sliders icon, obviously. clicking it.

...okay. temperature, top-p, top-k, those are there, fine, table stakes. scrolling down, is there more. repetition penalty, yes. is there min-p though — a lot of newer frontends still don't have it and i live and die by min-p over top-p these days. ...there it is, good, they didn't forget it.

what about DRY? that's newer, less common to see exposed. scrolling... don't see it. hm. mildly annoying but not a dealbreaker, i can live without it if everything else is solid.

is there a raw/advanced mode where i can just paste a json blob of sampler params instead of hunting through UI fields one at a time? that would tell me a lot about who built this — whether they actually run local models themselves or whether this is a wrapper built primarily for hosted API stuff with local support bolted on as an afterthought. checking... there's an "advanced" toggle or expand-all thing. clicking it.

yeah okay, more fields show up — mirostat mode, mirostat tau, that kind of thing. that's a good sign, mirostat is not something you add unless you or someone on the team actually uses koboldcpp/llama.cpp seriously.

adjusting temperature down a bit, bumping min-p, hitting save or does it apply live... not obvious if i need to hit an explicit save button or if it just takes effect next message. no confirmation toast or anything. a little uncertain whether it stuck.

sending another message to test if the setting actually changed anything. response comes back, feels a little tighter, more focused, consistent with what i'd expect from a lower temp. hard to be 100% sure from vibes alone but okay, cautiously trusting it did the thing.

still want to know: does this let me save these as a named preset per-character, or is it one global sampler config for every chat? because i run wildly different settings for a raw completion sandbox versus a chat character. looking around for a "save preset" button... there's something that looks like it, a dropdown near the top of the settings panel.

that's about where i am — connected to my own backend, card loaded, had a real exchange, poked at the sampler settings and they're mostly all there. still got open questions rattling around: whether context length actually got detected right, whether DRY sampling exists somewhere i haven't found, whether presets are per-character or global. not going to chase all of that down this second, but it's what's nagging at me as i keep clicking around.
