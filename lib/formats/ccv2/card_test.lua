if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local card = require("lib.formats.ccv2.card")
local json = require("lib.format.json")
local base64 = require("lib.encode.base64")
local png = require("lib.png")

T.describe("ccv2.card: from_json", function()
  T.it("parses a V2 card correctly", function()
    local input = json.encode({
      spec = "chara_card_v2",
      spec_version = "2.0",
      data = {
        name = "Alice",
        description = "A test character",
        personality = "Friendly",
        scenario = "Testing",
        first_mes = "Hello!",
        mes_example = "<START>",
        creator_notes = "Test notes",
        system_prompt = "Be helpful",
        tags = { "test", "demo" },
      },
    })
    local data, err = card.from_json(input)
    T.ok(data, err)
    T.eq(data.name, "Alice")
    T.eq(data.description, "A test character")
    T.eq(data.personality, "Friendly")
    T.eq(data.scenario, "Testing")
    T.eq(data.first_mes, "Hello!")
    T.eq(data.mes_example, "<START>")
    T.eq(data.creator_notes, "Test notes")
    T.eq(data.system_prompt, "Be helpful")
    T.eq(data.tags[1], "test")
    T.eq(data.tags[2], "demo")
    -- Defaults filled
    T.eq(data.post_history_instructions, "")
    T.eq(data.creator, "")
    T.eq(data.character_version, "")
    T.eq(type(data.alternate_greetings), "table")
    T.eq(#data.alternate_greetings, 0)
    T.eq(type(data.extensions), "table")
  end)

  T.it("auto-wraps a V1-only card", function()
    local input = json.encode({
      name = "Bob",
      description = "Old format",
      personality = "Calm",
      scenario = "",
      first_mes = "Hi",
      mes_example = "",
    })
    local data, err = card.from_json(input)
    T.ok(data, err)
    T.eq(data.name, "Bob")
    T.eq(data.description, "Old format")
    -- V2 defaults filled
    T.eq(data.creator_notes, "")
    T.eq(data.system_prompt, "")
    T.eq(type(data.tags), "table")
  end)

  T.it("errors on missing name", function()
    local input = json.encode({
      spec = "chara_card_v2",
      spec_version = "2.0",
      data = {
        description = "No name",
      },
    })
    local data, err = card.from_json(input)
    T.fail(data)
    T.ok(err)
  end)

  T.it("errors on empty name", function()
    local input = json.encode({
      spec = "chara_card_v2",
      spec_version = "2.0",
      data = {
        name = "",
        description = "Empty name",
      },
    })
    local data, err = card.from_json(input)
    T.fail(data)
    T.ok(err)
  end)

  T.it("errors on invalid JSON", function()
    local data, err = card.from_json("not json at all{{{")
    T.fail(data)
    T.ok(err)
  end)

  T.it("errors on object with no spec and no name", function()
    local input = json.encode({ description = "orphan" })
    local data, err = card.from_json(input)
    T.fail(data)
    T.ok(err)
  end)
end)

T.describe("ccv2.card: normalize", function()
  T.it("fills all defaults for empty table", function()
    local data = card.normalize({})
    T.eq(data.name, "")
    T.eq(data.description, "")
    T.eq(data.personality, "")
    T.eq(data.scenario, "")
    T.eq(data.first_mes, "")
    T.eq(data.mes_example, "")
    T.eq(data.creator_notes, "")
    T.eq(data.system_prompt, "")
    T.eq(data.post_history_instructions, "")
    T.eq(data.creator, "")
    T.eq(data.character_version, "")
    T.eq(type(data.alternate_greetings), "table")
    T.eq(#data.alternate_greetings, 0)
    T.eq(type(data.tags), "table")
    T.eq(#data.tags, 0)
    T.eq(type(data.extensions), "table")
  end)

  T.it("preserves existing values", function()
    local data = card.normalize({ name = "Test", tags = { "a", "b" } })
    T.eq(data.name, "Test")
    T.eq(data.tags[1], "a")
    T.eq(data.tags[2], "b")
  end)
end)

T.describe("ccv2.card: to_json / from_json round-trip", function()
  T.it("round-trips correctly", function()
    local original = {
      name = "Charlie",
      description = "Round-trip test",
      personality = "Witty",
      scenario = "A bar",
      first_mes = "Howdy",
      mes_example = "{{user}}: Hi\n{{char}}: Hey",
      creator_notes = "Created for testing",
      system_prompt = "You are Charlie",
      post_history_instructions = "Stay in character",
      alternate_greetings = { "Hey there", "Sup" },
      tags = { "test" },
      creator = "tester",
      character_version = "1.0",
    }
    local json_str, err = card.to_json(original)
    T.ok(json_str, err)

    local parsed, err2 = card.from_json(json_str)
    T.ok(parsed, err2)
    T.eq(parsed.name, "Charlie")
    T.eq(parsed.description, "Round-trip test")
    T.eq(parsed.personality, "Witty")
    T.eq(parsed.first_mes, "Howdy")
    T.eq(parsed.creator_notes, "Created for testing")
    T.eq(parsed.system_prompt, "You are Charlie")
    T.eq(parsed.post_history_instructions, "Stay in character")
    T.eq(parsed.alternate_greetings[1], "Hey there")
    T.eq(parsed.alternate_greetings[2], "Sup")
    T.eq(parsed.tags[1], "test")
    T.eq(parsed.creator, "tester")
    T.eq(parsed.character_version, "1.0")
  end)
end)

T.describe("ccv2.card: PNG round-trip", function()
  T.it("creates a PNG and reads it back", function()
    local data = {
      name = "PngTest",
      description = "PNG round-trip",
      first_mes = "Hello from PNG",
    }
    local png_bytes, err = card.to_png(data)
    T.ok(png_bytes, err)

    -- Verify it's valid PNG
    T.eq(png_bytes:sub(1, 4), "\137PNG")

    local parsed, err2 = card.from_png(png_bytes)
    T.ok(parsed, err2)
    T.eq(parsed.name, "PngTest")
    T.eq(parsed.description, "PNG round-trip")
    T.eq(parsed.first_mes, "Hello from PNG")
  end)

  T.it("preserves other chunks when given existing PNG", function()
    -- Create a minimal PNG with a custom tEXt chunk
    local chunks = {
      { type = "IHDR", data = "\0\0\0\1\0\0\0\1\8\6\0\0\0" },
      { type = "tEXt", data = "Author\0TestAuthor" },
      { type = "IDAT", data = "\x78\x01\x01\x05\x00\xFA\xFF\x00\x00\x00\x00\x00\x00\x06\x00\x01" },
      { type = "IEND", data = "" },
    }
    local existing_png = png.write(chunks)

    local data = { name = "Overlay", first_mes = "Hi" }
    local new_png, err = card.to_png(data, existing_png)
    T.ok(new_png, err)

    -- Read back and check both the card data and the Author chunk
    local new_chunks = png.read(new_png)
    T.ok(new_chunks)

    local author = png.get_text(new_chunks, "Author")
    T.eq(author, "TestAuthor")

    local parsed, err2 = card.from_png(new_png)
    T.ok(parsed, err2)
    T.eq(parsed.name, "Overlay")
  end)

  T.it("errors when no chara chunk in PNG", function()
    local chunks = {
      { type = "IHDR", data = "\0\0\0\1\0\0\0\1\8\6\0\0\0" },
      { type = "IDAT", data = "\x78\x01\x01\x05\x00\xFA\xFF\x00\x00\x00\x00\x00\x00\x06\x00\x01" },
      { type = "IEND", data = "" },
    }
    local png_bytes = png.write(chunks)

    local data, err = card.from_png(png_bytes)
    T.fail(data)
    T.ok(err)
    T.ok(err:find("chara"), "error should mention chara")
  end)

  T.it("errors on invalid PNG bytes", function()
    local data, err = card.from_png("not a png")
    T.fail(data)
    T.ok(err)
  end)
end)
