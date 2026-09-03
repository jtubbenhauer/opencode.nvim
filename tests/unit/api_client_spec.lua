local api_client = require('opencode.api_client')
local assert = require('luassert')

describe('api_client', function()
  local original_cli_version
  local state

  before_each(function()
    state = require('opencode.state')
    original_cli_version = state.opencode_cli_version
  end)

  after_each(function()
    state.jobs.set_opencode_cli_version(original_cli_version)
  end)

  it('should create a new client instance', function()
    local client = api_client.new('http://localhost:8080')
    assert.is_not_nil(client)
    assert.are.equal('http://localhost:8080', client.base_url)
  end)

  it('should remove trailing slash from base_url', function()
    local client = api_client.new('http://localhost:8080/')
    assert.are.equal('http://localhost:8080', client.base_url)
  end)

  it('should create client using create factory function', function()
    local client = api_client.create('http://localhost:8080')
    assert.is_not_nil(client)
    assert.are.equal('http://localhost:8080', client.base_url)
  end)

  it('should have all expected API methods', function()
    local client = api_client.new('http://localhost:8080')

    -- Project endpoints
    assert.is_function(client.list_projects)
    assert.is_function(client.get_current_project)

    -- Config endpoints
    assert.is_function(client.get_config)
    assert.is_function(client.update_config)
    assert.is_function(client.list_providers)

    -- Session endpoints
    assert.is_function(client.list_sessions)
    assert.is_function(client.create_session)
    assert.is_function(client.get_session)
    assert.is_function(client.delete_session)
    assert.is_function(client.update_session)
    assert.is_function(client.get_session_children)

    -- Message endpoints
    assert.is_function(client.list_messages)
    assert.is_function(client.create_message)
    assert.is_function(client.get_message)

    -- Find endpoints
    assert.is_function(client.find_text)
    assert.is_function(client.find_files)
    assert.is_function(client.find_symbols)

    -- File endpoints
    assert.is_function(client.list_files)
    assert.is_function(client.read_file)
    assert.is_function(client.get_file_status)

    -- Event endpoints
    assert.is_function(client.subscribe_to_events)
  end)

  it('should construct URLs correctly with query parameters', function()
    local server_job = require('opencode.server_job')
    local original_call_api = server_job.call_api
    local captured_calls = {}
    local original_cwd = vim.fn.getcwd
    local state = require('opencode.state')
    state.context.set_current_cwd('/current/directory')

    vim.fn.getcwd = function()
      return '/current/directory'
    end

    server_job.call_api = function(url, method, body)
      table.insert(captured_calls, { url = url, method = method, body = body })
      local promise = require('opencode.promise').new()
      promise:resolve({})
      return promise
    end

    local client = api_client.new('http://localhost:8080')

    -- Test without query params - directory should be URL-encoded
    client:list_projects()
    assert.are.equal('http://localhost:8080/project?directory=%2Fcurrent%2Fdirectory', captured_calls[1].url)
    assert.are.equal('GET', captured_calls[1].method)

    -- Test with query params - directory should be URL-encoded
    client:list_projects('/some/directory')
    assert.are.equal('http://localhost:8080/project?directory=%2Fsome%2Fdirectory', captured_calls[2].url)

    -- Test with multiple query params
    client:list_tools('anthropic', 'claude-3', '/some/dir')
    local actual_url = captured_calls[3].url

    -- Check base URL and endpoint
    assert.is_true(actual_url:find('http://localhost:8080/experimental/tool?') == 1)

    -- Check that all expected parameters are present (order doesn't matter)
    assert.is_not_nil(actual_url:find('provider=anthropic'))
    assert.is_not_nil(actual_url:find('model=claude%-3')) -- Escape the dash
    assert.is_not_nil(actual_url:find('directory=%%2Fsome%%2Fdir')) -- URL-encoded path

    -- Restore original function
    server_job.call_api = original_call_api
    vim.fn.getcwd = original_cwd
  end)

  it('normalizes /global/event payloads into legacy event shape', function()
    local server_job = require('opencode.server_job')
    local original_stream_api = server_job.stream_api
    local Promise = require('opencode.promise')
    state.jobs.set_opencode_cli_version(Promise.new():resolve('1.14.42'))

    local received = {}

    server_job.stream_api = function(_, _, _, on_chunk)
      on_chunk(
        'data: ' .. vim.json.encode({
          payload = {
            id = 'evt_1',
            type = 'session.status',
            properties = {
              sessionID = 'ses_1',
              status = { type = 'busy' },
            },
          },
        })
      )

      return { shutdown = function() end }
    end

    local client = api_client.new('http://localhost:8080')
    client:subscribe_to_events('/some/directory', function(event)
      table.insert(received, event)
    end)

    assert.same({
      {
        id = 'evt_1',
        type = 'session.status',
        properties = {
          sessionID = 'ses_1',
          status = { type = 'busy' },
        },
      },
    }, received)

    server_job.stream_api = original_stream_api
  end)

  it('normalizes /global/event sync payloads into legacy event shape', function()
    local server_job = require('opencode.server_job')
    local original_stream_api = server_job.stream_api
    local Promise = require('opencode.promise')
    state.jobs.set_opencode_cli_version(Promise.new():resolve('1.14.42'))

    local received = {}

    server_job.stream_api = function(_, _, _, on_chunk)
      on_chunk(
        'data: ' .. vim.json.encode({
          payload = {
            type = 'sync',
            syncEvent = {
              id = 'evt_2',
              type = 'message.part.updated.1',
              data = {
                sessionID = 'ses_1',
                part = {
                  id = 'prt_1',
                  type = 'text',
                  text = 'hello',
                  messageID = 'msg_1',
                  sessionID = 'ses_1',
                },
              },
            },
            id = 'evt_2',
          },
        })
      )

      return { shutdown = function() end }
    end

    local client = api_client.new('http://localhost:8080')
    client:subscribe_to_events('/some/directory', function(event)
      table.insert(received, event)
    end)

    assert.same({
      {
        id = 'evt_2',
        type = 'message.part.updated',
        properties = {
          sessionID = 'ses_1',
          part = {
            id = 'prt_1',
            type = 'text',
            text = 'hello',
            messageID = 'msg_1',
            sessionID = 'ses_1',
          },
        },
      },
    }, received)

    server_job.stream_api = original_stream_api
  end)

  describe('directory scoping in a linked worktree', function()
    local url_encode = require('opencode.util').url_encode
    local server_job = require('opencode.server_job')
    local client
    local tmp, main, linked
    local captured
    local original_call_api
    local original_getcwd
    local original_current_cwd

    ---Directory the last captured request was scoped to.
    ---@return string|nil
    local function requested_directory()
      local last = captured[#captured]
      return last and last.url:match('directory=([^&]+)')
    end

    before_each(function()
      tmp = vim.fn.tempname()
      main = tmp .. '/main'
      linked = tmp .. '/linked'
      vim.fn.mkdir(main, 'p')

      local function git(args)
        local cmd = { 'git', '-C', main }
        vim.list_extend(cmd, args)
        vim.fn.system(cmd)
      end

      vim.fn.system({ 'git', 'init', '-q', main })
      git({ 'config', 'user.email', 'test@example.com' })
      git({ 'config', 'user.name', 'Test' })
      git({ 'commit', '-q', '--allow-empty', '-m', 'init' })
      git({ 'worktree', 'add', '-q', '--detach', linked })

      captured = {}
      original_call_api = server_job.call_api
      server_job.call_api = function(url, method, body)
        table.insert(captured, { url = url, method = method, body = body })
        return require('opencode.promise').new():resolve({})
      end

      original_getcwd = vim.fn.getcwd
      vim.fn.getcwd = function()
        return linked
      end

      original_current_cwd = state.current_cwd
      state.context.set_current_cwd(linked)

      client = api_client.new('http://localhost:8080')
    end)

    after_each(function()
      server_job.call_api = original_call_api
      vim.fn.getcwd = original_getcwd
      state.context.set_current_cwd(original_current_cwd)
      vim.fn.delete(tmp, 'rf')
    end)

    it('creates sessions in the worktree, not the main repo', function()
      client:create_session()
      assert.are.equal(url_encode(linked), requested_directory())
    end)

    it('sends prompts to the worktree', function()
      client:create_message('ses_1', { parts = {} })
      assert.are.equal(url_encode(linked), requested_directory())
    end)

    it('reads file status from the worktree', function()
      client:get_file_status()
      assert.are.equal(url_encode(linked), requested_directory())
    end)

    it('lists sessions against the main worktree', function()
      client:list_sessions()
      assert.are.equal(url_encode(main), requested_directory())
    end)

    it('lists session status against the main worktree', function()
      client:list_session_status()
      assert.are.equal(url_encode(main), requested_directory())
    end)

    it('still honours an explicitly passed directory', function()
      client:list_sessions(linked)
      assert.are.equal(url_encode(linked), requested_directory())
    end)
  end)
end)
