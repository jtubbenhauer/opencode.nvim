local util = require('opencode.util')
local state = require('opencode.state')
local config_file = require('opencode.config_file')
local Promise = require('opencode.promise')
local M = {}

---Get the current OpenCode project ID
---@return string|nil
M.project_id = Promise.async(function()
  local project = config_file.get_opencode_project():await()
  if not project then
    vim.notify('No OpenCode project found in the current directory', vim.log.levels.ERROR)
    return nil
  end
  return project.id
end)

---Get the base storage path for OpenCode
---@return string
function M.get_storage_path()
  local home = vim.uv.os_homedir()
  return home .. '/.local/share/opencode/storage'
end

---Get the session storage path for the current workspace
---@return string
M.get_workspace_session_path = Promise.async(function(project_id)
  project_id = project_id or M.project_id():await() or ''
  local home = vim.uv.os_homedir()
  return home .. '/.local/share/opencode/storage/session/' .. project_id
end)

function M.get_cache_path(session_id)
  local cache_base = vim.fn.stdpath('cache') .. '/opencode/session/'
  return cache_base .. session_id
end

---Sessions the server reports for the current project, keyed on the project's
---worktree rather than the session's recorded directory. Sessions started in a
---linked worktree record that worktree's path, so a directory-scoped lookup
---misses them even though they belong to the same project.
---@return Session[]|nil
local function list_project_sessions(limit)
  if not util.is_git_project() then
    return nil
  end

  if type(state.api_client.list_sessions_global) ~= 'function' then
    return nil
  end

  local root = util.project_root(state.current_cwd or vim.fn.getcwd())
  local ok, all = pcall(function()
    return state.api_client:list_sessions_global({ limit = limit }):await()
  end)
  if not ok or type(all) ~= 'table' then
    return nil
  end

  return vim.tbl_filter(function(session)
    return session.project and session.project.worktree == root
  end, all)
end

---Get all workspace sessions, sorted and filtered
---@return Session[]|nil
M.get_all_workspace_sessions = Promise.async(function()
  local limit = require('opencode.config').values.session_list_limit
  local sessions = state.api_client:list_sessions(nil, { limit = limit }):await()

  -- The directory-scoped list above misses sibling worktrees, while the global
  -- list is capped across every project at once. Merging them keeps a busy
  -- project from crowding a quiet one out of its own history.
  local project_sessions = list_project_sessions(limit)
  if project_sessions and #project_sessions > 0 then
    local merged = {}
    local seen = {}
    for _, list in ipairs({ sessions or {}, project_sessions }) do
      for _, session in ipairs(list) do
        if session.id and not seen[session.id] then
          seen[session.id] = true
          merged[#merged + 1] = session
        end
      end
    end
    sessions = merged
  end

  if not sessions then
    return nil
  end

  -- Validate that sessions is actually a table/array, not an error string
  if type(sessions) ~= 'table' then
    vim.notify('Error: list_sessions returned invalid data: ' .. tostring(sessions), vim.log.levels.ERROR)
    return nil
  end

  table.sort(sessions, function(a, b)
    return a.time.updated > b.time.updated
  end)

  if not util.is_git_project() then
    -- we only want sessions that are in the current workspace_folder
    sessions = vim.tbl_filter(function(session)
      if session.directory and vim.startswith(vim.fn.getcwd(), session.directory) then
        return true
      end
      return false
    end, sessions)
  end

  return sessions
end)

---Get all sessions across every project (no workspace filter)
---@return GlobalSession[]|nil
M.get_all_global_sessions = Promise.async(function()
  local sessions = state.api_client:list_sessions_global():await()
  if not sessions or type(sessions) ~= 'table' then
    return nil
  end

  table.sort(sessions, function(a, b)
    return a.time.updated > b.time.updated
  end)

  return sessions
end)

---Get the most recent main workspace session
---@return Session|nil
M.get_last_workspace_session = Promise.async(function()
  local sessions = M.get_all_workspace_sessions():await()
  ---@cast sessions Session[]|nil
  if not sessions then
    return nil
  end

  local main_sessions = vim.tbl_filter(function(session)
    return session.parentID == nil --- we don't want child sessions
  end, sessions)

  return main_sessions[1]
end)

---Get a session by its id
---@param id string
---@return Promise<Session|nil>
M.get_by_id = Promise.async(function(id)
  if not id or id == '' then
    return nil
  end
  return state.api_client:get_session(id):await()
end)

---Get messages for a session
---@param session Session
---@param opts? { limit?: number } Optional query parameters (e.g. limit)
---@return Promise<OpencodeMessage[]>
function M.get_messages(session, opts)
  if not session then
    return Promise.new():resolve(nil)
  end

  return state.api_client:list_messages(session.id, nil, opts)
end

---Get snapshot IDs from a message's parts
---@param message OpencodeMessage?
---@return string[]|nil
function M.get_message_snapshot_ids(message)
  if not message then
    return nil
  end
  local snapshot_ids = {}
  for _, part in ipairs(message.parts or {}) do
    if part.type == 'patch' and part.hash and not vim.tbl_contains(snapshot_ids, part.hash) then
      table.insert(snapshot_ids, part.hash)
    end
  end
  return #snapshot_ids > 0 and snapshot_ids or nil
end

return M
