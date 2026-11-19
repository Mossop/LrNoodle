local lr = require("lr_stubs")
local json = require("json")

-- json.lua is a vendored copy of rxi/json.lua. These only check the basics and the
-- parts changed to work inside Lightroom.
describe("json", function()
  before_each(function()
    lr.reset()
  end)

  it("round trips nested values", function()
    local value = { name = "photo", tags = { "a", "b" }, rating = 3.5, picked = false, meta = {} }
    assert.are.same(value, json.decode(json.encode(value)))
  end)

  it("escapes strings", function()
    assert.are.equal('"a\\"b\\\\c\\nd\\u0001"', json.encode('a"b\\c\nd\1'))
  end)

  it("decodes unicode escapes", function()
    assert.are.equal("é", json.decode('"\\u00e9"'))
    assert.are.equal("€", json.decode('"\\u20ac"'))
  end)

  it("decodes surrogate pairs", function()
    assert.are.equal("😀", json.decode('"\\ud83d\\ude00"'))
  end)

  it("rejects values it cannot encode", function()
    assert.has_error(function()
      json.encode({ 1, nil, 3 })
    end)
    assert.has_error(function()
      json.encode({ [1] = "a", b = "c" })
    end)
    assert.has_error(function()
      json.encode(math.huge)
    end)
    assert.has_error(function()
      json.encode(function() end)
    end)
  end)

  it("rejects circular references", function()
    local value = {}
    value.self = value
    assert.has_error(function()
      json.encode(value)
    end)
  end)

  it("reports where decoding failed", function()
    local ok, err = pcall(json.decode, '{\n  "a": tru\n}')
    assert.is_false(ok)
    assert.matches("invalid literal 'tru' at line 2 col 8", err)
  end)

  it("rejects trailing garbage", function()
    assert.has_error(function()
      json.decode("[1] 2")
    end)
  end)
end)
