local log = require('smart-splits.log')

local ESC = string.char(0x1b)

local function create_tcp_client(host_or_path, port)
  local host = (host_or_path == 'localhost') and '127.0.0.1' or host_or_path
  local client = vim.uv.new_tcp()
  client:connect(host, port, function(err)
    if err then
      return error(err)
    end
    log.debug('Connected to TCP socket at %s:%d', host, port)
  end)
  return client
end

local function create_unix_client(socket_path)
  local client = vim.uv.new_pipe(false)
  client:connect(socket_path)
  log.debug('Connected to Unix socket at %s', socket_path)
  return client
end

local function parse_address(addr)
  -- TCP format: tcp:host:port or just host:port
  local tcp_match = addr:match('^tcp:([^:]+):(%d+)$')
  if tcp_match then
    local host, port = addr:match('^tcp:([^:]+):(%d+)$')
    return 'tcp', host, tonumber(port)
  end

  -- Try host:port without tcp: prefix
  local host, port = addr:match('^([^:]+):(%d+)$')
  if host and port then
    return 'tcp', host, tonumber(port)
  end

  -- Unix format: unix:path or just /path
  local unix_match = addr:match('^unix:(.+)$')
  if unix_match then
    return 'unix', unix_match, nil
  end

  -- If it starts with /, assume unix socket
  if addr:match('^/') then
    return 'unix', addr, nil
  end

  return nil, 'Invalid address format: ' .. addr
end

local function create_client(addr)
  if not addr or addr == '' then
    return nil
  end

  local conn_type, host_or_path, port = parse_address(addr)

  if not conn_type then
    error(host_or_path)
  end

  if conn_type == 'tcp' then
    return create_tcp_client(host_or_path, port)
  end

  return create_unix_client(host_or_path)
end

local remove_control_sequences = function(data)
  local pattern = ESC .. 'P@kitty%-cmd(.-)' .. ESC .. '\\'
  local cleaned = data:gsub(pattern, '%1')
  return cleaned
end

local function build_kitty_cmd(cmd, direction, amount)
  local password = vim.g.smart_splits_kitty_password or require('smart-splits.config').kitty_password or ''
  local command = {}
  local no_response = true

  if cmd == 'ls' then
    no_response = false
    command = {
      cmd = cmd,
    }
  elseif cmd == 'neighboring_window' then
    command = {
      cmd = 'action',
      payload = { action = 'neighboring_window ' .. direction },
    }
  elseif cmd == 'resize-window' then
    local axis = (direction == 'left' or direction == 'right') and 'horizontal' or 'vertical'
    local increment = (direction == 'left' or direction == 'down') and -amount or amount
    command = {
      cmd = cmd,
      payload = { match = 'id:' .. vim.env.KITTY_WINDOW_ID, self = true, increment = increment, axis = axis },
    }
  elseif cmd == 'split_window' then
    log.debug('Are this functions being used?')
    command = {
      cmd = cmd,
    }
  else
    error('Unsupported command: ' .. cmd)
  end

  command.no_response = no_response
  -- Kitty docs: "Using a version greater than the version of the kitty instance you are talking to, will cause a failure."
  command.version = { 0, 14, 2 }
  command.kitty_window_id = tonumber(vim.env.KITTY_WINDOW_ID) or 0
  if password ~= '' then
    command.password = password
  end

  local json_cmd = vim.json.encode(command)
  log.debug('Built Kitty command: %s', json_cmd)

  local kitty_cmd = ESC .. 'P@kitty-cmd' .. json_cmd .. ESC .. '\\'

  return kitty_cmd, not no_response
end

M = {
  data = {},
  client = create_client(vim.env.KITTY_LISTEN_ON),
}

function M.kitty_cmd(cmd, direction, amount)
  local kitty_cmd, update_data = build_kitty_cmd(cmd, direction, amount)
  M.__write_to_socket(kitty_cmd)

  if not update_data then
    return 0
  end

  M.__update_data_from_socket()
end

function M.refresh()
  if not M.client then
    return
  end
  M.kitty_cmd('ls')
end

function M.get_data()
  return M.data
end

function M.__update_data_from_socket()
  vim.uv.read_start(M.client, function(err, data)
    if err then
      error(err)
    end
    local cleaned = remove_control_sequences(data)
    local decoded = vim.json.decode(cleaned)
    M.data = vim.json.decode(decoded.data)
    vim.uv.read_stop(M.client)
  end)
end

function M.__write_to_socket(data)
  M.client:write(data)
end

function M.__close_socket()
  if not M.client:is_closing() then
    M.client:close()
  end
end

return M
