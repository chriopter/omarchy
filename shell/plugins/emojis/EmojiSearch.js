function parseEmojis(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    return Array.isArray(data) ? data : []
  } catch (e) {
    return []
  }
}

// Use counts keyed by emoji, e.g. { "👍": 12 }.
function parseUsage(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    return data && typeof data === "object" && !Array.isArray(data) ? data : {}
  } catch (e) {
    return {}
  }
}

function normalizedQuery(query) {
  return String(query || "").trim().toLowerCase()
}

function keywordText(item) {
  return String((item && item.k) || "").toLowerCase()
}

function filterEmojis(emojis, query, limit) {
  var values = Array.isArray(emojis) ? emojis : []
  var needle = normalizedQuery(query)
  var max = limit === undefined || limit === null ? 1000 : Number(limit)
  if (isNaN(max)) max = 1000
  max = Math.max(0, max)
  if (max === 0) return []

  var out = []

  for (var i = 0; i < values.length; i++) {
    var item = values[i]
    if (!item || !item.e) continue
    if (!needle || keywordText(item).indexOf(needle) >= 0) {
      out.push(item)
      if (out.length >= max) break
    }
  }

  return out
}

// Emojis ranked by use count, topped up from the catalog so the rows stay full.
function mostUsed(emojis, counts, count) {
  var top = Object.keys(counts).sort(function(a, b) { return counts[b] - counts[a] }).slice(0, Math.max(0, count))
  var values = Array.isArray(emojis) ? emojis : []
  for (var i = 0; top.length < count && i < values.length; i++) {
    if (values[i] && values[i].e && top.indexOf(values[i].e) < 0) top.push(values[i].e)
  }
  return top
}

if (typeof module !== "undefined") {
  module.exports = {
    parseEmojis: parseEmojis,
    parseUsage: parseUsage,
    normalizedQuery: normalizedQuery,
    filterEmojis: filterEmojis,
    mostUsed: mostUsed
  }
}
