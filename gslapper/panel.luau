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
                if kind and accepted[kind] then
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

render = function()
    local visible, total, pages = visibleEntries()
    local children = {
        ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = tr("panel.title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
            ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
        }),
        ui.label({ text = scanError or tr("panel.media_count", { count = total }), color = scanError and "error" or "on_surface_variant" }),
    }
    for _, entry in ipairs(visible) do
        table.insert(children, ui.label({ text = entry.name }))
    end
    table.insert(children, ui.label({ text = tostring(page) .. " / " .. tostring(pages) }))
    panel.render(ui.column({ padding = 16, gap = 8, flexGrow = 1 }, children))
end

function onOpen(_context)
    thumbnailsAvailable = noctalia.commandExists("gst-launch-1.0")
    rescan()
    render()
end

function onCloseClicked()
    panel.close()
end

return {
    classifyName = classifyName,
    safeChild = safeChild,
    sortEntries = sortEntries,
    fnv1a32 = fnv1a32,
}
