--!nonstrict

local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph") or "wallpaper-selector")
  barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

function onClick()
  noctalia.togglePanel("nomadcxx/gslapper:picker")
end

function onConfigChanged()
  render()
end

render()
