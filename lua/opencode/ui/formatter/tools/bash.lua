local icons = require('opencode.ui.icons')
local M = {}

---@param value any
---@return string
local function one_line(value)
  if type(value) ~= 'string' then
    return ''
  end
  return vim.trim(value:gsub('[\r\n]+', ' '))
end

---@param output Output
---@param part OpencodeMessagePart
function M.format(output, part)
  if part.tool ~= 'bash' then
    return
  end

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  ---@type BashToolInput
  local input = part.state and part.state.input or {}

  ---@type BashToolMetadata
  local metadata = part.state and part.state.metadata or {}

  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('run'), 'run', input.description, utils.get_duration_text(part))

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  if metadata.output or metadata.command or input.command then
    local command = input.command or metadata.command or ''
    local command_output = metadata.output and metadata.output ~= '' and ('\n' .. metadata.output) or ''
    utils.format_code(output, vim.split('> ' .. command .. '\n' .. command_output, '\n'), 'bash')
  end

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param _ OpencodeMessagePart
---@param input BashToolInput
---@param metadata BashToolMetadata
---@return string, string, string
function M.summary(_, input, metadata)
  metadata = metadata or {}
  local command = input.command
  if not command or command == '' then
    command = metadata.command
  end
  return icons.get('run'), 'run', one_line(command or input.description or '')
end

return M
