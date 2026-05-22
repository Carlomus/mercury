-- Tests for mercury.markdown_out — the styler that turns text/markdown
-- output payloads into virt_lines chunks. Verifies that the standard
-- markdown highlight groups (@markup.heading.N, @markup.strong,
-- @markup.emphasis, @markup.raw.*, @markup.list.markdown,
-- @markup.quote.markdown) land on the right spans. SPEC Invariant 33.

local MdOut = require("mercury.markdown_out")

local function joined(line_chunks)
  local s = ""
  for _, ch in ipairs(line_chunks) do s = s .. ch[1] end
  return s
end

local function has_hl(line_chunks, target_hl)
  for _, ch in ipairs(line_chunks) do
    if ch[2] == target_hl then return true end
  end
  return false
end

local function chunk_with_text(line_chunks, target_text)
  for _, ch in ipairs(line_chunks) do
    if ch[1] == target_text then return ch end
  end
  return nil
end

describe("markdown_out.chunks", function()
  it("returns an empty list for nil/empty input", function()
    assert.same({}, MdOut.chunks(nil))
    assert.same({}, MdOut.chunks(""))
  end)

  it("preserves line count from the source", function()
    local src = "line one\nline two\nline three"
    local result = MdOut.chunks(src)
    assert.equals(3, #result)
    assert.equals("line one", joined(result[1]))
    assert.equals("line two", joined(result[2]))
    assert.equals("line three", joined(result[3]))
  end)

  it("highlights ATX headings 1-6 with the matching @markup.heading.N hl group", function()
    local src = "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6"
    local result = MdOut.chunks(src)
    for i = 1, 6 do
      assert.is_true(has_hl(result[i], ("@markup.heading.%d.markdown"):format(i)),
        ("level %d heading should use @markup.heading.%d.markdown"):format(i, i))
    end
  end)

  it("does NOT promote 7+ `#`s to a heading", function()
    -- ATX limits headings to 1-6 octothorpes. A line with 7 `#`s is plain text.
    local result = MdOut.chunks("####### not a heading")
    assert.is_false(has_hl(result[1], "@markup.heading.7.markdown"))
  end)

  it("requires a space after the hashes (so `#hashtag` isn't a heading)", function()
    local result = MdOut.chunks("#hashtag")
    assert.is_false(has_hl(result[1], "@markup.heading.1.markdown"))
  end)

  it("renders **bold** with @markup.strong, leaving surrounding text default", function()
    local result = MdOut.chunks("a **bold** word")
    local chunks = result[1]
    -- The bold span (`**bold**`) carries @markup.strong.
    assert.is_not_nil(chunk_with_text(chunks, "**bold**"))
    assert.is_true(has_hl(chunks, "@markup.strong"))
    -- The default text around it is NOT @markup.strong.
    local prefix = chunk_with_text(chunks, "a ")
    assert.is_not_nil(prefix)
    assert.is_not.equals("@markup.strong", prefix[2])
  end)

  it("renders *italic* with @markup.emphasis", function()
    local result = MdOut.chunks("an *italic* word")
    assert.is_true(has_hl(result[1], "@markup.emphasis"))
    assert.is_not_nil(chunk_with_text(result[1], "*italic*"))
  end)

  it("prefers bold over italic when both could match the same span", function()
    -- `**x**` must be parsed as bold, not as two empty italics around x.
    local result = MdOut.chunks("**x**")
    assert.is_not_nil(chunk_with_text(result[1], "**x**"))
    assert.is_true(has_hl(result[1], "@markup.strong"))
    -- No bare-italic mis-match would have produced a `*` chunk on its own.
    for _, ch in ipairs(result[1]) do
      assert.is_not.equals("*", ch[1])
    end
  end)

  it("renders `inline code` with @markup.raw.markdown_inline", function()
    local result = MdOut.chunks("see `os.path.join`")
    assert.is_true(has_hl(result[1], "@markup.raw.markdown_inline"))
    assert.is_not_nil(chunk_with_text(result[1], "`os.path.join`"))
  end)

  it("renders a fenced code block (``` ... ```) as raw markdown", function()
    local src = "```python\nx = 1\n```\nafter"
    local result = MdOut.chunks(src)
    -- Opening fence, body, closing fence: all @markup.raw.markdown.
    assert.is_true(has_hl(result[1], "@markup.raw.markdown"))
    assert.is_true(has_hl(result[2], "@markup.raw.markdown"))
    assert.is_true(has_hl(result[3], "@markup.raw.markdown"))
    -- Line after the closing fence is back to default styling.
    assert.is_false(has_hl(result[4], "@markup.raw.markdown"))
  end)

  it("renders bullet-list markers with @markup.list.markdown", function()
    for _, marker in ipairs({ "-", "*", "+" }) do
      local result = MdOut.chunks(marker .. " an item")
      assert.is_true(has_hl(result[1], "@markup.list.markdown"),
        "bullet marker " .. marker .. " should highlight as @markup.list.markdown")
    end
  end)

  it("renders ordered-list markers with @markup.list.markdown", function()
    local result = MdOut.chunks("1. first\n2. second")
    assert.is_true(has_hl(result[1], "@markup.list.markdown"))
    assert.is_true(has_hl(result[2], "@markup.list.markdown"))
  end)

  it("renders > blockquote with @markup.quote.markdown", function()
    local result = MdOut.chunks("> a quote")
    assert.is_true(has_hl(result[1], "@markup.quote.markdown"))
  end)

  it("renders a horizontal rule as a Comment-style separator", function()
    for _, hr in ipairs({ "---", "***", "___" }) do
      local result = MdOut.chunks(hr)
      assert.is_true(has_hl(result[1], "Comment"),
        "horizontal rule " .. hr .. " should highlight as Comment")
    end
  end)

  it("composes inline emphasis inside list items", function()
    local result = MdOut.chunks("- a **bold** point")
    -- Has both the list marker hl AND the strong span hl.
    assert.is_true(has_hl(result[1], "@markup.list.markdown"))
    assert.is_true(has_hl(result[1], "@markup.strong"))
  end)
end)

describe("markdown_out integration with output.build_virt_lines", function()
  -- The text/markdown branch in output.lua delegates to markdown_out.chunks
  -- and emits one virt_line per styled line. Confirm a multi-chunk line
  -- arrives intact (not collapsed to its first chunk by the single-chunk
  -- packing path).
  it("emits multi-chunk virt_lines for inline-styled markdown output", function()
    local Output = require("mercury.output")
    local out = {
      status = "ok",
      items = { {
        type = "display_data",
        data = { ["text/markdown"] = "a **bold** word" },
        metadata = {},
      } },
    }
    local virt = Output.build_virt_lines(out, { show_status_pill = false })
    -- The styled line must contain more than one chunk (default prefix +
    -- strong span + default suffix). If the packer were wrapping the
    -- entire chunk list as a single chunk (the regression), we'd only see
    -- one chunk per virt_line.
    local multi_chunk_seen = false
    for _, vl in ipairs(virt) do
      if #vl >= 2 then multi_chunk_seen = true; break end
    end
    assert.is_true(multi_chunk_seen)
  end)

  it("style hl groups appear in build_virt_lines output", function()
    local Output = require("mercury.output")
    local out = {
      status = "ok",
      items = { {
        type = "display_data",
        data = { ["text/markdown"] = "# Heading\n\n- bullet\n\nsee `code`" },
        metadata = {},
      } },
    }
    local virt = Output.build_virt_lines(out, { show_status_pill = false })
    local all_hls = {}
    for _, vl in ipairs(virt) do
      for _, ch in ipairs(vl) do all_hls[ch[2]] = true end
    end
    assert.is_true(all_hls["@markup.heading.1.markdown"], "heading hl present")
    assert.is_true(all_hls["@markup.list.markdown"], "list hl present")
    assert.is_true(all_hls["@markup.raw.markdown_inline"], "inline code hl present")
  end)
end)
