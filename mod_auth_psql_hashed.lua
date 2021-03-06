-- PostgreSQL hashed password authentication module for Prosody IM
-- Lots of code borrowed from mod_auth_sql and some from mod_auth_wordpress
-- Copyright (C) 2011 Tomasz Sterna <tomek@xiaoka.com>
-- Copyright (C) 2011 Waqas Hussain <waqas20@gmail.com>
-- Copyright (C) 2011 Kim Alvefur
-- Copyright (C) 2014 Brian Curran <brian@brianpcurran.com>

-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:

-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.

-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
-- IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
-- CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
-- TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
-- SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

local log = require "util.logger".init("auth_psql_hashed");
local new_sasl = require "util.sasl".new;
local DBI = require "DBI";
local connection;
local params = module:get_option("auth_psql_hashed", module:get_option("sql"));
local users_table = module:get_option_string("psql_users_table", "users");
local localpart = module:get_option_string("psql_localpart_column", "localpart");
local domainpart = module:get_option_string("psql_domainpart_column", "domainpart");
local password_column = module:get_option_string("psql_password_column", "password");

local function test_connection()
  if not connection then return nil; end
  if connection:ping() then
    return true;
  else
   module:log("debug", "Database connection closed");
   connection = nil;
  end
end

local function connect()
  if not test_connection() then
    prosody.unlock_globals();
    local dbh, err = DBI.Connect(
      params.driver, params.database,
      params.username, params.password,
      params.host, params.port
    );
    prosody.lock_globals();
    if not dbh then
      module:log("error", "Database connection failed: %s", tostring(err));
      return nil, err;
    end
    module:log("debug", "Successfully connected to database");
    dbh:autocommit(true); -- don't run in transaction
    connection = dbh;
    return connection;
  end
end

do -- process options to get a db connection
  params = params;
  if params.driver ~= "PostgreSQL" then
    error("This module only supports PostgreSQL");
  end
  assert(params.driver and params.database, "Both the SQL driver and the database need to be specified");
  assert(connect());
end

local function getsql(sql, ...)
  if params.driver == "PostgreSQL" then
    sql = sql:gsub("`", "\"");
  end
  if not test_connection() then connect(); end
  -- do prepared statement stuff
  local stmt, err = connection:prepare(sql);
  if not stmt and not test_connection() then error("connection failed"); end
  if not stmt then module:log("error", "QUERY FAILED: %s %s", err, debug.traceback()); return nil, err; end
  -- run query
  local ok, err = stmt:execute(...);
  if not ok and not test_connection() then error("connection failed"); end
  if not ok then return nil, err; end
  return stmt;
end

local function setsql(sql, ...)
  local stmt, err = getsql(sql, ...);
  if not stmt then return stmt, err; end
  return stmt:affected();
end

provider = {};

function provider.test_password(username, password)
  local stmt, err = getsql("SELECT `"..password_column.."` = crypt(?, `"..password_column.."`) AS `pwd_check_result` FROM `"..users_table.."` WHERE `"..localpart.."`=? AND `"..domainpart.."`=?", password, username, module.host);
  for row in stmt:rows(true) do
    return row.pwd_check_result;
  end
end

function provider.get_password(username)
  return nil, "Hashed passwords are not available";
end

function provider.set_password(username, password)
  local stmt, err = setsql("UPDATE `"..users_table.."` SET `"..password_column.."` = crypt(?, gen_salt('bf')) WHERE `"..localpart.."`=?", password, username);
  if stmt then
    return true;
  end
  return nil, "Failed to set password";
end

function provider.user_exists(username)
  local stmt, err = getsql("SELECT `"..localpart.."` FROM `"..users_table.."` WHERE `"..localpart.."`=?", username);
  if stmt then
    return true;
  end
end

function provider.create_user(username, password)
  local stmt, err = setsql("INSERT INTO `"..users_table.."` (`"..localpart.."`, `"..domainpart.."`, `"..password_column.."`) VALUES (?, ?, crypt(?, gen_salt('bf')))", username, module.host, password);
  if stmt then
    return true;
  end
  return nil, "Failed to create user";
end

function provider.get_sasl_handler()
  local profile = {
    plain_test = function(sasl, username, password, realm)
      return provider.test_password(username, password), true;
    end
  };
  return new_sasl(module.host, profile);
end

function provider.users()
  local stmt, err = getsql("SELECT `"..localpart.."` AS `username` FROM `"..users_table.."` WHERE `"..domainpart.."`=?", module.host);
  if stmt then
    local next, state = stmt:rows(true);
    return function()
      for row in next, state do
        return row.username;
      end
    end
  end
  return stmt, err;
end

module:provides("auth", provider);
