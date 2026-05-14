# cr-repo — a protocol for stuff you actually own

This is a friendly tour of what cr-repo is, why it exists, and how to use it. For the normative spec, see [cr-repo-spec.md](./cr-repo-spec.md).

The `cr-` prefix is a placeholder; the name will change.

## The problem

You spent five years on chub.ai writing characters. One morning the policy changed and they're all gone. You spent a decade on Tumblr. 2018 happened. You built an audience on Twitter. The terms changed. You sold games on a platform. The platform got acquired and shut down.

The pattern: someone else owns the floor your work stands on. When they tilt it, you fall.

This protocol is for things that should not fall when a platform tilts. It does not solve "how do I make centralized platforms be nice." It assumes they won't.

## What this is (and isn't)

cr-repo is a protocol for **local-first repositories**: collections of content that live on your computer first, and can be shared with others by any means you choose. Files on disk. URLs you control. USB sticks. A peer-to-peer network. Email. Whatever.

It is not:

- A blockchain. There is no global ledger. There is no consensus mechanism. There are no tokens.
- A peer-to-peer overlay you must run. You can use DHT-style discovery if you want, but you don't have to.
- A specific app or service. It's a format and a set of rules. Anyone can build apps on top.
- An attempt to make moderation impossible. You moderate your own feed by choosing who you follow. There is no centralized moderation; there is also no centralized "no moderation."

It **is**:

- A way to write content that doesn't depend on any specific host being alive.
- A way to follow specific people whose work you want, without those people needing any platform's permission.
- A way to make curated lists, write bookmarks, post images, share code, whatever — in a format that other tools can read without asking anyone.
- A way to do all of the above, today, with a text editor and a static web host you already have.

## A bundle in 30 seconds

Here is a file you can hand-type. Save it as `my-bookmarks.json`, put it anywhere a web browser can fetch it, and you have published a cr-repo bundle.

```json
{
  "cr-type": "cr-bundle",
  "records": [
    {
      "cr-type": "cr-record",
      "ref": null,
      "metadata": {
        "types": ["collection"],
        "title": "Cool sites I found this week",
        "description": "Mostly weird old web stuff."
      },
      "created": "2026-05-14T10:00:00Z"
    },
    {
      "cr-type": "cr-record",
      "ref": { "kind": "uri", "uri": "https://www.cameronsworld.net/" },
      "metadata": {
        "types": ["bookmark"],
        "title": "Cameron's World",
        "id": "cameronsworld"
      },
      "created": "2026-05-14T10:01:00Z"
    },
    {
      "cr-type": "cr-record",
      "ref": { "kind": "uri", "uri": "https://wiby.me/" },
      "metadata": {
        "types": ["bookmark"],
        "title": "Wiby — search engine for the classic web",
        "id": "wiby"
      },
      "created": "2026-05-14T10:02:00Z"
    }
  ]
}
```

That's it. A friend with a cr-repo reader points at the URL of that file and sees your bookmarks. No account, no API key, no platform.

To update it: edit the file, re-upload. To remove an entry: edit the file, re-upload. The file is yours.

## Following someone

A maker is a person (or a thing, or a bot) with a public keypair. They publish signed pages — bundles that come with a cryptographic signature proving the maker wrote them. You "follow" a maker by storing their public key and periodically fetching their latest page.

When the maker publishes a new page, your reader sees it. When they unsubscribe from a host and move to a new one, the network of resolvers (DHT, rendezvous servers, whatever you've configured) finds them at the new place.

You don't have to be a maker. You can hand-write bundles forever and never sign anything. Bundles are useful on their own. Signing is for "this is provably from me, and you can detect tampering" — useful when you care about authorship, less useful when you don't.

You also don't have to be followed. You can read makers' content without anyone knowing. There is no follow-back, no notifications, no engagement metric, unless someone builds those on top.

## Why not just use a centralized platform

A centralized platform offers convenience. It also makes specific promises that cr-repo deliberately doesn't.

The platform promises:

- One place to log in.
- Discovery of new content via algorithmic feeds and global search.
- Moderation that catches the worst stuff (sometimes).
- A persistent identity tied to your account.

cr-repo offers none of those things directly. Instead:

- **You log in to your own machine.** Apps that speak cr-repo run on it. They sync with whatever hosts you point them at.
- **Discovery is social.** You find new makers through curated lists, friends, links in other bundles. There is no algorithmic feed because there is no central feed to algorithm. (You can build one yourself over your own follow graph if you want.)
- **Moderation is who you follow.** If someone publishes things you don't want to see, unfollow them. If a curator curates badly, fork or replace their list. There is no one to ban anyone from anywhere because there is no central anywhere.
- **Identity is a keypair you hold.** Lose the key, lose the identity. Back it up.

In exchange you get:

- **No one can take your stuff down.** Your bundles live on whatever hosts you choose. If one goes down, you move. If you go down, the people who mirrored your stuff still have it.
- **No one can take your audience.** Followers store your pubkey, not a username on someone else's database. When you move hosts, they find you.
- **No one can change the rules underneath you.** A protocol can be extended; it cannot be retroactively narrowed. Your old bundles stay valid forever.
- **You can leave whenever, taking everything.** Your repo is files on disk. Tar them up. Move them. Done.

This is a deliberate trade. It is the right trade for some uses (your art, your writing, your friend group, your knowledge base) and the wrong trade for others (mass-market consumer apps that need centralized identity recovery, content moderation, and search-from-zero). The protocol does not try to be both.

## Why not just use ActivityPub / Nostr / IPFS / AT Protocol

Honest comparisons, briefly:

- **ActivityPub** (Mastodon, etc.) is server-centric. Your "home server" still owns your identity, your follower list, and your content. If your server goes away or kicks you off, you have a portability protocol but a painful migration. ActivityPub also designs heavily around the social-media use case; using it to publish, say, a curated list of bookmarks is awkward.
- **Nostr** is closer in spirit — relay-based, key-pair identity, no central anything. But it's optimized for short messages and short relays' tolerance for them. Storing large content (a long document, an image, a bundle) doesn't fit; you end up bolting on external hosts anyway. cr-repo treats "large stuff lives anywhere; small signed pointers tie it together" as a first-class design.
- **IPFS** is heavy on content addressing — everything is a hash — and weak on identity, mutability, and "the latest version of X." cr-repo lets you use content addressing when you want it (and not when you don't), and treats identity and mutability as separate concerns with their own modules.
- **AT Protocol** (Bluesky) is the closest cousin: keypair identity, per-user repos, content addressing, pluggable hosts. It's larger and more opinionated, particularly about the social-graph schema and the lexicon system. cr-repo is smaller, more modular, and deliberately makes no schema-level commitments — you compose what you want.

A pattern across all four: each is opinionated about a use case. cr-repo is opinionated about *modularity* and lets the use case be whatever you bring.

## How hard is it to write your own bundles?

The bundle above is the whole answer. A bundle is a JSON file. A record is a JSON object with a `ref`, some `metadata`, and a `created` date. A record can point at:

- Nothing (`"ref": null`) — for free-floating notes, descriptions, or list headers.
- A URL (`"ref": {"kind": "uri", "uri": "..."}`) — for bookmarks, references to other repos, links to anything on the web.
- A local file path — for things on your own machine.
- (Optionally, if you want hashing) a content hash — for verifiable references to specific bytes.
- (Optionally, if you've adopted identity) another maker's pubkey — for following or recommending people.

Metadata is open. Put a title, a description, tags, ratings, whatever. Apps that recognize specific fields will use them; others will preserve them untouched. You will not get punished for writing weird fields.

Hand-authoring covers:
- Notes and sticky-note style snippets.
- Markdown documents (inline or pointing at a file).
- Images and other media (pointing at URLs or local files).
- Bookmarks with descriptions and notes.
- Curated lists of makers, sites, or anything else.
- Code snippets with mimetypes.
- References to games, profiles, products — anything addressable by URL.

Hand-authoring does not cover:
- Signing as a specific maker (needs cryptography).
- Content-addressed (hash-based) references (needs hashing).

If you don't need those, you don't load them. The protocol is modular; the parts you don't load aren't there.

## Intended limitations

These are not shortcomings to apologize for — they are the design.

- **No global search.** There is no service that knows everything published in the protocol, because there is no protocol-level place for such a service to plug in. Search exists only within what you have locally (your follows, your follows' lists, content you've explicitly fetched). If you want broader search, someone builds an optional indexer that crawls public repos and serves a search API — but that service is not part of the protocol, and you don't have to use it.
- **No global ranking, trending, or popularity.** Same reason. If you want "what's hot," that's a service on top, not a substrate concern.
- **Discovery of new makers is social.** You find them through curated lists, friends, links in other people's bundles. There is no algorithmic introduction. Bootstrapping a brand-new user with no follows is genuinely harder than it is on a centralized platform — the honest answer is "import a starter list of makers you might like," same as RSS clients ship with sample feeds.
- **No central moderation.** No one can ban anyone from the protocol. People can be unfollowed by you, removed from curated lists you trust, and ignored — but they cannot be erased from the network. This means bad actors persist if anyone hosts them; it also means you cannot be erased by a bad actor with admin access.
- **Lose your key, lose your identity.** There is no password reset. There is no support email. Back up your keys, or accept that the identity is mortal.
- **Mirroring is your job.** If you care about your content surviving your hosts going down, run mirrors, ask friends to mirror, or use multiple resolution paths. The protocol gives you the tools; using them is on you.

These are all consequences of the same root choice: no central anything. Reverse them and you're back at the centralized platform you came from.

## What you actually need to start

If you want to read cr-repo content: an app that speaks the protocol. (None of these exist yet at the time of writing; they're being built.)

If you want to publish without identity:
- A text editor.
- A place to put files where others can fetch them (a static web host, a tilde-site, an S3 bucket, anywhere).
- A bundle file like the one above.

If you want to publish as a signed maker:
- The above, plus an app that handles signing and key storage.
- An Ed25519 keypair (the app generates this).
- A backup of the private key, kept somewhere safe.

The first two are deliberately enough to participate meaningfully. The third unlocks following-and-being-followed.

## Where to go next

- [cr-repo-spec.md](./cr-repo-spec.md) — the normative protocol spec. Framework + module catalog. Read this if you're implementing or extending.
- (Tools, libraries, and example repos: coming.)

If you're trying to decide whether this is for you: it probably is if you have ever lost work to a platform decision, or expect to. It probably isn't if you want one app to install and zero thinking required. It can become the second one over time, once tools mature, but it will never stop being the first one.
