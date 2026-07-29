--!nonstrict

local IMAGE_EXTENSIONS = { jpg = true, jpeg = true, png = true, webp = true, jxl = true, bmp = true }
local VIDEO_EXTENSIONS = { mp4 = true, mkv = true, webm = true, mov = true, avi = true, m4v = true, gif = true }
local PAGE_SIZE = 12
local THUMBNAIL_LIMIT = 4

local filter = "all"
local search = ""
local page = 1
local currentRoot = nil
local currentDirectory = nil
local entries = {}
local scanError = nil
local thumbnailJobs = {}
local thumbnailQueue = {}
local thumbnailActive = 0
local thumbnailsAvailable = false
local assignments = noctalia.state.get("assignments") or {}
local runtime = noctalia.state.get("runtime") or {}
local capabilities = noctalia.state.get("capabilities") or { video = false, checking = true }
local outputs = noctalia.state.get("outputs") or {}
local commandResult = noctalia.state.get("command_result")
local selectedOutput = "*"
local nonceCounter = 0
local outputOptions = {}
local render

local function tr(key, substitutions)
    return noctalia.tr(key, substitutions)
end

local function trimTrailingSlash(path)
    if type(path) ~= "string" then
        return nil
    end
    path = path:gsub("/+$", "")
    return path == "" and "/" or path
end

local function roots()
    local image = trimTrailingSlash(noctalia.wallpaperDirectory())
    local configured = noctalia.getConfig("video_directory")
    local video = trimTrailingSlash(type(configured) == "string" and noctalia.expandPath(configured) or nil)
    return image, video
end

local function classifyName(name)
    if type(name) ~= "string" then
        return nil
    end
    local extension = name:match("%.([^./]+)$")
    extension = extension and extension:lower() or nil
    if extension == "gif" then
        return "video"
    elseif extension and IMAGE_EXTENSIONS[extension] then
        return "image"
    elseif extension and VIDEO_EXTENSIONS[extension] then
        return "video"
    end
    return nil
end

local function safeChild(root, directory, name)
    root = trimTrailingSlash(root)
    directory = trimTrailingSlash(directory)
    if not root or not directory or type(name) ~= "string" or name == "" or name == "." or name == ".."
        or name:find("/", 1, true) or name:find("[\n\r%z]") then
        return nil
    end
    if directory ~= root and directory:sub(1, #root + 1) ~= root .. "/" then
        return nil
    end
    return (directory == "/" and "" or directory) .. "/" .. name
end

local function sortEntries(values)
    table.sort(values, function(left, right)
        if left.kind == "directory" and right.kind ~= "directory" then
            return true
        elseif left.kind ~= "directory" and right.kind == "directory" then
            return false
        end
        local leftName = left.name:lower()
        local rightName = right.name:lower()
        return leftName == rightName and left.name < right.name or leftName < rightName
    end)
end

local function assignmentMatchCount(values, connectors, path)
    local count = 0
    for _, connector in ipairs(connectors or {}) do
        if values[connector] and values[connector].path == path then
            count = count + 1
        end
    end
    return count
end

local function mixedCounts(values, connectors)
    local counts = { video = 0, image = 0, unassigned = 0 }
    for _, connector in ipairs(connectors or {}) do
        local assignment = values[connector]
        if assignment and assignment.kind == "video" then
            counts.video = counts.video + 1
        elseif assignment and assignment.kind == "image" then
            counts.image = counts.image + 1
        else
            counts.unassigned = counts.unassigned + 1
        end
    end
    return counts
end

local function fnv1a32(value)
    local hash = 2166136261
    for index = 1, #value do
        hash = bit32.bxor(hash, value:byte(index))
        local low = (hash % 65536) * 16777619
        local high = (math.floor(hash / 65536) * 16777619) % 65536
        hash = (low + high * 65536) % 4294967296
    end
    return string.format("%08x", hash)
end

local function shellQuote(value)
    if type(value) ~= "string" or value:find("[\n\r%z]") then
        return nil
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function thumbnailPath(path, info)
    local directory = noctalia.pluginDataDir()
    if not directory then
        return nil
    end
    local fingerprint = path .. ":" .. tostring(info.size or 0) .. ":" .. tostring(info.mtime or 0)
    return directory .. "/thumb-" .. fnv1a32(fingerprint) .. ".png"
end

local function startThumbnailJobs()
    while thumbnailsAvailable and thumbnailActive < THUMBNAIL_LIMIT and #thumbnailQueue > 0 do
        local job = table.remove(thumbnailQueue, 1)
        if thumbnailJobs[job.path] == "queued" then
            thumbnailJobs[job.path] = "running"
            thumbnailActive = thumbnailActive + 1
            local temporary = job.thumbnail .. ".tmp"
            local command = "gst-launch-1.0 -q filesrc location=" .. shellQuote(job.path)
                .. " ! decodebin ! videoconvert ! videoscale ! video/x-raw,width=320"
                .. " ! pngenc snapshot=true ! filesink location=" .. shellQuote(temporary)
            local started = noctalia.runAsync(command, function(result)
                thumbnailActive = thumbnailActive - 1
                if result.exitCode == 0 and noctalia.fileExists(temporary) then
                    local renamed = noctalia.renameFile(temporary, job.thumbnail)
                    thumbnailJobs[job.path] = renamed and "ready" or "failed"
                else
                    noctalia.removeFile(temporary)
                    thumbnailJobs[job.path] = "failed"
                end
                startThumbnailJobs()
                if render then
                    render()
                end
            end, 15000)
            if not started then
                thumbnailActive = thumbnailActive - 1
                thumbnailJobs[job.path] = "failed"
            end
        end
    end
end

local function queueThumbnail(entry)
    if not thumbnailsAvailable or entry.kind ~= "video" then
        return
    end
    local info = noctalia.fileInfo(entry.path)
    if not info or info.isDir then
        return
    end
    local cached = thumbnailPath(entry.path, info)
    entry.thumbnail = cached
    if cached and noctalia.fileExists(cached) then
        thumbnailJobs[entry.path] = "ready"
    elseif cached and not thumbnailJobs[entry.path] then
        thumbnailJobs[entry.path] = "queued"
        table.insert(thumbnailQueue, { path = entry.path, thumbnail = cached })
    end
end

local function scanDirectory(rootKind, root, directory, accepted)
    local names, message = noctalia.listDir(directory)
    if not names then
        return false, message or "directory is unreadable"
    end
    for _, name in ipairs(names) do
        local path = safeChild(root, directory, name)
        if path then
            local info = noctalia.fileInfo(path)
            if info and info.isDir then
                table.insert(entries, {
                    name = name,
                    path = path,
                    kind = "directory",
                    root = root,
                    rootKind = rootKind,
                })
            elseif info then
                local kind = classifyName(name)
                local allowedVideo = rootKind ~= "image" or name:lower():match("%.gif$") ~= nil
                if kind and accepted[kind] and (kind ~= "video" or allowedVideo) then
                    local entry = { name = name, path = path, kind = kind, root = root, rootKind = rootKind }
                    queueThumbnail(entry)
                    table.insert(entries, entry)
                end
            end
        end
    end
    return true
end

local function rescan()
    entries = {}
    scanError = nil
    local imageRoot, videoRoot = roots()
    local ok = true
    local messages = {}

    if currentDirectory then
        local accepted = filter == "images" and { image = true }
            or filter == "videos" and { video = true }
            or { image = true, video = true }
        local scanned, message = scanDirectory(currentRoot.kind, currentRoot.path, currentDirectory, accepted)
        ok = scanned
        if not scanned then
            table.insert(messages, message)
        end
    else
        if filter ~= "videos" and imageRoot then
            local scanned, message = scanDirectory("image", imageRoot, imageRoot, { image = true, video = true })
            ok = ok and scanned
            if not scanned then table.insert(messages, message) end
        end
        if filter ~= "images" and videoRoot and videoRoot ~= imageRoot then
            local scanned, message = scanDirectory("video", videoRoot, videoRoot, { video = true })
            ok = ok and scanned
            if not scanned then table.insert(messages, message) end
        end
    end

    if not ok then
        scanError = table.concat(messages, "; ")
    end
    sortEntries(entries)
    page = math.max(1, math.min(page, math.max(1, math.ceil(#entries / PAGE_SIZE))))
    startThumbnailJobs()
end

local function visibleEntries()
    local filtered = {}
    local needle = search:lower()
    for _, entry in ipairs(entries) do
        if needle == "" or entry.name:lower():find(needle, 1, true) then
            table.insert(filtered, entry)
        end
    end
    local pages = math.max(1, math.ceil(#filtered / PAGE_SIZE))
    page = math.max(1, math.min(page, pages))
    local first = (page - 1) * PAGE_SIZE + 1
    local visible = {}
    for index = first, math.min(#filtered, first + PAGE_SIZE - 1) do
        table.insert(visible, filtered[index])
    end
    return visible, #filtered, pages
end

local function connectorNames()
    local names = {}
    for _, output in ipairs(outputs or {}) do
        local name = type(output) == "table" and output.name or output
        if type(name) == "string" and name ~= "" then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

local function nextNonce()
    nonceCounter = nonceCounter + 1
    return noctalia.nowMs() * 1000 + nonceCounter
end

local function sendCommand(action, entry)
    local command = {
        nonce = nextNonce(),
        action = action,
        target = action == "restore-all" and "*" or selectedOutput,
    }
    if entry then
        command.path = entry.path
        command.preview_path = entry.thumbnail and noctalia.fileExists(entry.thumbnail) and entry.thumbnail or nil
    end
    noctalia.state.set("command", command)
end

local function selectedConnectors()
    return selectedOutput == "*" and connectorNames() or { selectedOutput }
end

local function selectionBusy()
    for _, connector in ipairs(selectedConnectors()) do
        if runtime[connector] and runtime[connector].status == "starting" then
            return true
        end
    end
    return false
end

local function navigateDirectory(entry)
    local rootQuoted = shellQuote(entry.root)
    local childQuoted = shellQuote(entry.path)
    if not rootQuoted or not childQuoted then
        return
    end
    local command = "readlink -f -- " .. rootQuoted .. "\nreadlink -f -- " .. childQuoted
    noctalia.runAsync(command, function(result)
        local canonicalRoot, canonicalChild = (result.stdout or ""):match("^([^\n]+)\n([^\n]+)")
        if result.exitCode ~= 0 or not canonicalRoot or not canonicalChild
            or (canonicalChild ~= canonicalRoot and canonicalChild:sub(1, #canonicalRoot + 1) ~= canonicalRoot .. "/") then
            scanError = tr("panel.navigation_blocked")
            render()
            return
        end
        currentRoot = { kind = entry.rootKind, path = entry.root }
        currentDirectory = entry.path
        search = ""
        page = 1
        rescan()
        render()
    end, 2000)
end

local function navigateUp()
    if not currentDirectory or not currentRoot then
        return
    end
    if currentDirectory == currentRoot.path then
        currentDirectory = nil
        currentRoot = nil
    else
        local parent = currentDirectory:match("^(.*)/[^/]+$")
        if not parent or parent == currentRoot.path then
            currentDirectory = currentRoot.path
        else
            currentDirectory = parent
        end
    end
    search = ""
    page = 1
    rescan()
    render()
end

local function tileFor(entry, connectors)
    local matches = assignmentMatchCount(assignments, connectors, entry.path)
    local selected = #connectors > 0 and matches == #connectors
    local videoDisabled = entry.kind == "video" and not capabilities.video
    local busy = selectionBusy()
    local preview
    if entry.kind == "directory" then
        preview = ui.column({ height = 108, radius = 8, fill = "surface_variant/0.55", align = "center", justify = "center" }, {
            ui.glyph({ name = "folder", size = 42, color = "primary" }),
        })
    elseif entry.kind == "image" or (entry.thumbnail and noctalia.fileExists(entry.thumbnail)) then
        preview = ui.image({
            path = entry.kind == "image" and entry.path or entry.thumbnail,
            height = 108,
            fit = "cover",
            radius = 8,
        })
    else
        preview = ui.column({ height = 108, radius = 8, fill = "surface_variant/0.55", align = "center", justify = "center" }, {
            ui.glyph({ name = "player-play", size = 36, color = videoDisabled and "outline" or "secondary" }),
        })
    end

    local badges = {}
    if entry.kind == "video" then
        table.insert(badges, ui.label({ text = tr("panel.video_badge"), fontSize = 10, color = "secondary", fontWeight = "bold" }))
    end
    if selectedOutput == "*" and matches > 0 and matches < #connectors then
        table.insert(badges, ui.label({
            text = tr("panel.partial_badge", { count = matches, total = #connectors }),
            fontSize = 10,
            color = "primary",
            fontWeight = "bold",
        }))
    end

    local props = {
        key = entry.path,
        width = 210,
        gap = 6,
        padding = 7,
        radius = 10,
        border = selected and "primary" or "outline/0.45",
        borderWidth = selected and 2 or 1,
        fill = selected and "primary/0.08" or "surface_variant/0.20",
        opacity = videoDisabled and 0.55 or 1,
    }
    if entry.kind == "directory" then
        props.onClick = function() navigateDirectory(entry) end
    elseif not videoDisabled and not busy then
        props.onClick = function()
            sendCommand(entry.kind == "image" and "assign-image" or "assign-video", entry)
        end
    end

    return ui.column(props, {
        preview,
        ui.label({ text = entry.name, maxLines = 1, maxWidth = 196, fontSize = 11, fontWeight = "bold" }),
        ui.row({ gap = 6, align = "center" }, badges),
    })
end

local function activeStrip(connectors)
    if selectedOutput == "*" then
        local counts = mixedCounts(assignments, connectors)
        return ui.row({ align = "center", gap = 8, padding = 9, radius = 9, fill = "surface_variant/0.40" }, {
            ui.glyph({ name = "devices", color = "primary", size = 18 }),
            ui.label({
                text = tr("panel.mixed_summary", {
                    outputs = #connectors,
                    videos = counts.video,
                    images = counts.image,
                }),
                flexGrow = 1,
                maxLines = 1,
            }),
            ui.button({
                text = tr("panel.pause_videos"),
                variant = "ghost",
                enabled = counts.video > 0 and not selectionBusy(),
                onClick = function() sendCommand("pause") end,
            }),
            ui.button({
                text = tr("panel.restore_all"),
                variant = "ghost",
                enabled = #connectors > 0 and not selectionBusy(),
                onClick = function() sendCommand("restore-all") end,
            }),
        })
    end

    local assignment = assignments[selectedOutput]
    local live = runtime[selectedOutput]
    if not assignment then
        return nil
    end
    local isVideo = assignment.kind == "video"
    local paused = live and live.status == "paused"
    return ui.row({ align = "center", gap = 8, padding = 9, radius = 9, fill = "surface_variant/0.40" }, {
        ui.glyph({ name = isVideo and "movie" or "photo", color = isVideo and "secondary" or "primary", size = 18 }),
        ui.column({ flexGrow = 1, gap = 2 }, {
            ui.label({ text = assignment.path:match("([^/]+)$") or assignment.path, fontWeight = "bold", maxLines = 1 }),
            ui.label({
                text = live and tr("panel.status_" .. tostring(live.status)) or tr("panel.status_static"),
                fontSize = 10,
                color = live and live.error and "error" or "on_surface_variant",
            }),
        }),
        ui.button({
            text = tr(paused and "panel.resume" or "panel.pause"),
            variant = "ghost",
            visible = isVideo,
            enabled = live ~= nil and not selectionBusy(),
            onClick = function() sendCommand(paused and "resume" or "pause") end,
        }),
        ui.button({
            text = tr("panel.restore"),
            variant = "ghost",
            enabled = not selectionBusy(),
            onClick = function() sendCommand("restore") end,
        }),
    })
end

local function resultBanner()
    if not commandResult or type(commandResult.summary) ~= "table" then
        return nil
    end
    local summary = commandResult.summary
    if (summary.pending or 0) > 0 then
        return ui.label({ text = tr("panel.applying"), color = "on_surface_variant" })
    end
    local errors = {}
    for connector, result in pairs(commandResult.results or {}) do
        if result.ok == false then
            table.insert(errors, connector .. ": " .. tostring(result.error))
        end
    end
    table.sort(errors)
    if #errors > 0 then
        return ui.label({ text = table.concat(errors, "  ·  "), color = "error", maxLines = 2 })
    end
    return ui.label({
        text = tr("panel.applied_summary", { count = summary.successful or 0, total = summary.total or 0 }),
        color = "secondary",
    })
end

render = function()
    local visible, total, pages = visibleEntries()
    local connectors = connectorNames()
    outputOptions = { tr("panel.all_outputs") }
    local selectedIndex = 0
    for index, connector in ipairs(connectors) do
        table.insert(outputOptions, connector)
        if selectedOutput == connector then
            selectedIndex = index
        end
    end
    if selectedOutput ~= "*" and selectedIndex == 0 then
        selectedOutput = "*"
    end

    local children = {
        ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = tr("panel.title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
            ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("panel.settings"), onClick = "onOpenSettings" }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = tr("panel.close"), onClick = "onCloseClicked" }),
        }),
        ui.row({ align = "center", gap = 8 }, {
            ui.input({
                key = "search-" .. filter .. "-" .. selectedOutput,
                value = search,
                placeholder = tr("panel.search"),
                focus = true,
                flexGrow = 1,
                onChange = "onSearchChanged",
            }),
            ui.select({
                options = outputOptions,
                selectedIndex = selectedIndex,
                width = 170,
                onChange = "onOutputChanged",
            }),
        }),
        ui.row({ align = "center", gap = 6 }, {
            ui.button({ text = tr("panel.filter_all"), selected = filter == "all", variant = "ghost", onClick = "onFilterAll" }),
            ui.button({ text = tr("panel.filter_images"), selected = filter == "images", variant = "ghost", onClick = "onFilterImages" }),
            ui.button({ text = tr("panel.filter_videos"), selected = filter == "videos", variant = "ghost", onClick = "onFilterVideos" }),
            ui.spacer({ flexGrow = 1 }),
            ui.button({
                glyph = "arrow-up",
                text = tr("panel.up"),
                variant = "ghost",
                visible = currentDirectory ~= nil,
                onClick = "onNavigateUp",
            }),
        }),
    }

    if capabilities.checking then
        table.insert(children, ui.label({ text = tr("panel.checking_dependencies"), color = "on_surface_variant" }))
    elseif not capabilities.video then
        table.insert(children, ui.column({
            gap = 3,
            padding = 9,
            radius = 8,
            fill = "error/0.10",
            border = "error/0.45",
            borderWidth = 1,
        }, {
            ui.label({ text = tr("panel.video_unavailable"), color = "error", fontWeight = "bold" }),
            ui.label({ text = tostring(capabilities.error or ""), fontSize = 11, color = "on_surface_variant" }),
        }))
    end

    local active = activeStrip(connectors)
    if active then table.insert(children, active) end
    local result = resultBanner()
    if result then table.insert(children, result) end

    if scanError then
        table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
            ui.glyph({ name = "alert-circle", size = 32, color = "error" }),
            ui.label({ text = tr("panel.directory_unreadable"), color = "error", fontWeight = "bold" }),
            ui.label({ text = scanError, color = "on_surface_variant", maxLines = 2 }),
        }))
    elseif total == 0 then
        table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
            ui.glyph({ name = "photo-off", size = 36, color = "outline" }),
            ui.label({
                text = search ~= "" and tr("panel.no_search_results") or tr("panel.directory_empty"),
                color = "on_surface_variant",
            }),
        }))
    else
        local rows = {}
        local row = {}
        for index, entry in ipairs(visible) do
            table.insert(row, tileFor(entry, selectedConnectors()))
            if #row == 4 or index == #visible then
                table.insert(rows, ui.row({ gap = 10, align = "start" }, row))
                row = {}
            end
        end
        table.insert(children, ui.scroll({ gap = 10, flexGrow = 1, align = "stretch" }, rows))
    end

    table.insert(children, ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.media_count", { count = total }), color = "on_surface_variant", fontSize = 11, flexGrow = 1 }),
        ui.button({ glyph = "chevron-left", variant = "ghost", enabled = page > 1, onClick = "onPreviousPage" }),
        ui.label({ text = tr("panel.page", { page = page, pages = pages }), fontSize = 11 }),
        ui.button({ glyph = "chevron-right", variant = "ghost", enabled = page < pages, onClick = "onNextPage" }),
    }))
    panel.render(ui.column({ padding = 16, gap = 10, flexGrow = 1 }, children))
end

function onOpen(_context)
    thumbnailsAvailable = noctalia.commandExists("gst-launch-1.0")
    outputs = noctalia.state.get("outputs") or noctalia.outputs() or {}
    assignments = noctalia.state.get("assignments") or {}
    runtime = noctalia.state.get("runtime") or {}
    capabilities = noctalia.state.get("capabilities") or capabilities
    rescan()
    render()
end

function onCloseClicked()
    panel.close()
end

function onOpenSettings()
    noctalia.openSettings()
end

function onSearchChanged(value)
    search = tostring(value or "")
    page = 1
    render()
end

local function setFilter(value)
    filter = value
    currentDirectory = nil
    currentRoot = nil
    page = 1
    rescan()
    render()
end

function onFilterAll() setFilter("all") end
function onFilterImages() setFilter("images") end
function onFilterVideos() setFilter("videos") end

function onOutputChanged(index, _label)
    selectedOutput = index == 0 and "*" or outputOptions[index + 1] or "*"
    page = 1
    render()
end

function onNavigateUp() navigateUp() end

function onPreviousPage()
    page = math.max(1, page - 1)
    render()
end

function onNextPage()
    page = page + 1
    render()
end

noctalia.state.watch("assignments", function(value)
    assignments = type(value) == "table" and value or {}
    render()
end)
noctalia.state.watch("runtime", function(value)
    runtime = type(value) == "table" and value or {}
    render()
end)
noctalia.state.watch("capabilities", function(value)
    capabilities = type(value) == "table" and value or capabilities
    render()
end)
noctalia.state.watch("outputs", function(value)
    outputs = type(value) == "table" and value or {}
    render()
end)
noctalia.state.watch("command_result", function(value)
    commandResult = value
    render()
end)

return {
    classifyName = classifyName,
    safeChild = safeChild,
    sortEntries = sortEntries,
    fnv1a32 = fnv1a32,
    assignmentMatchCount = assignmentMatchCount,
    mixedCounts = mixedCounts,
}
