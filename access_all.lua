-----  access_all by zj  -----
local optl = require("optl")
local ngx_var = ngx.var
local ngx_ctx = ngx.ctx
local ngx_unescape_uri = ngx.unescape_uri

-- 经测试可直接用request_id,无重复产生 openresty >= 1.11.0.0
ngx_ctx.request_guid = ngx_var.request_id

-- 传入 (host,remoteIp)
-- ipfromset.ips 异常处理
local loc_getRealIp = optl.loc_getRealIp

-- 获取所有参数的内容
	local remoteIp = ngx_var.remote_addr
	local host = ngx_unescape_uri(ngx_var.http_host)

	--- STEP 0
	local ip = loc_getRealIp(host,remoteIp)
	
	local method = ngx_var.request_method
	local request_uri = ngx_unescape_uri(ngx_var.request_uri)
	local uri = ngx_unescape_uri(ngx_var.uri)
	local useragent = ngx_unescape_uri(ngx_var.http_user_agent)
	local referer = ngx_unescape_uri(ngx_var.http_referer)
	local cookie = ngx_unescape_uri(ngx_var.http_cookie)
	local query_string = ngx_unescape_uri(ngx_var.query_string)

	local headers = ngx.req.get_headers()
	local headers_data = ngx_unescape_uri(ngx.req.raw_header(false))

	local args = ngx.req.get_uri_args()
	local args_data = optl.get_table(args)

	local posts = {}
	local post_data = ""
	if method == "POST" then
		posts = ngx.req.get_post_args()
		post_data = optl.get_table(posts)
	end

local base_msg = {}
	-- string 类型http参数
	base_msg.remoteIp = remoteIp
	base_msg.host = host
	base_msg.ip = ip
	base_msg.method = method
	base_msg.request_uri = request_uri
	base_msg.uri = uri
	base_msg.useragent = useragent
	base_msg.referer = referer
	base_msg.cookie = cookie
	base_msg.query_string = query_string

	-- table 类型参数
	base_msg.headers = headers
	base_msg.args = args
	base_msg.posts = posts

	-- table_str
	base_msg.headers_data = headers_data
	base_msg.args_data = args_data
	base_msg.post_data = post_data

local config_dict = ngx.shared.config_dict
local limit_ip_dict = ngx.shared.limit_ip_dict
local ip_dict = ngx.shared.ip_dict
local host_dict = ngx.shared.host_dict

local cjson_safe = require "cjson.safe"
local config_base = cjson_safe.decode(config_dict:get("base")) or {}


local host_Mod_state = host_dict:get(host)

--- 2016年8月4日 增加全局Mod开关
--  增加基于host的过滤模块开关判断
if config_base["Mod_state"] == "off" or host_Mod_state == "off" then
	return
end

--- 判断config_dict中模块开关是否开启
local config_is_on = optl.config_is_on

--- 取config_dict中的json数据
local getDict_Config = optl.getDict_Config

--- remath(str,re_str,options)
--- 常用二阶匹配规则
local remath = optl.remath

--- 匹配 host 和 uri
local function host_uri_remath(_host,_uri)
	if _host == nil or _uri == nil then
		return false
	end
	if remath(host,_host[1],_host[2]) and remath(uri,_uri[1],_uri[2]) then
		return true
	end
end

--- 拦截计数 2016年6月7日 21:52:52 up 从全局变成local
local Set_count_dict = optl.set_count_dict

-- action_deny(code) 拒绝访问
local function action_deny()
	-- 2016年9月19日
	-- 增加Mod_state = log , host_Mod state = log
	-- 在拒绝请求都进行了log记录，仅ip黑名单的没有记录（因为量的问题），故可直接return
	if config_base["Mod_state"] == "log" or host_Mod_state == "log" then
		return
	end
	if config_base.denyMsg.state == "on" then
		local tb = getDict_Config("denyMsg")
		local host_deny_msg = tb[host] or {}
		local tp_denymsg = type(host_deny_msg.deny_msg)
		if tp_denymsg == "number" then
			ngx.exit(host_deny_msg.deny_msg)
		elseif tp_denymsg == "string" then
			ngx.header.content_type = "text/html"
			ngx.say(host_deny_msg.deny_msg)
			ngx.exit(200)
		end
	end
	if type(config_base.denyMsg.msg) == "number" then
		ngx.exit(config_base.denyMsg.msg)
	else
		ngx.header.content_type = "text/html"
		ngx.say(tostring(config_base.denyMsg.msg))
		ngx.exit(200)
	end
end

---  STEP 1 
-- black/white ip 访问控制(黑/白名单/log记录)
-- 2016年7月29日19:12:53 检查
if config_is_on("ip_Mod") then
	local _ip_v = ip_dict:get(ip) --- 全局IP 黑白名单
	if _ip_v ~= nil then
		if _ip_v == "allow" then -- 跳出后续规则
			return
		elseif _ip_v == "log" then 
			Set_count_dict("ip log count")
	 		optl.debug(base_msg,"log","ip.log")
		else
			Set_count_dict(ip)
			action_deny()
		end
	end
	-- 基于host的ip黑白名单 eg:www.abc.com-101.111.112.113
	local tmp_host_ip = host.."-"..ip
	local host_ip = ip_dict:get(tmp_host_ip)
	if host_ip ~= nil then
		if host_ip == "allow" then -- 跳出后续规则
			return
		elseif host_ip == "log" then
			Set_count_dict(tmp_host_ip.." log count")
	 		optl.debug(base_msg,"log",host..".log")
		else
			Set_count_dict(tmp_host_ip)
			action_deny()
		end
	end
end

---  STEP 2
-- host and method  访问控制(白名单)
if config_is_on("host_method_Mod") then
	local tb_mod = getDict_Config("host_method_Mod")
	local check
	for i,v in ipairs(tb_mod) do
		if v.state == "on" then
			if remath(host,v.hostname[1],v.hostname[2]) and remath(method,v.method[1],v.method[2]) then
				check = "allow"
				break
			end
		end
	end
	if check ~= "allow" then
		Set_count_dict("host_method deny count")
	 	optl.debug(base_msg,"deny","host_method.log")
	 	action_deny()
	end
end

--- STEP 3
-- rewrite 跳转阶段(set-cookie)
-- 本来想着放到rewrite阶段使用的，方便统一都放到access阶段了。
if config_is_on("rewrite_Mod") then
	local tb_mod = getDict_Config("rewrite_Mod")
	for i,v in ipairs(tb_mod) do
		if v.state == "on" and host_uri_remath(v.hostname,v.uri) then

			if v.action[1] == "set-cookie" then
				local token = ngx.md5(v.action[2] .. ip)
				local token_name = v.action[3] or "token"
				-- 没有设置 tokenname 默认就是 token
	            if (ngx_var["cookie_"..token_name] ~= token) then
	                ngx.header["Set-Cookie"] = {token_name.."=" .. token}
	                if method == "POST" then
	                	return ngx.redirect(request_uri,307)
	                else
	                	return ngx.redirect(request_uri)
	                end
	            end
			elseif v.action[1] == "set-url" then
			-- 备用 使用url尾巴跳转方式进行验证
				
			end
			
		end
	end
end

--- STEP 4
-- host_Mod 规则过滤
-- 动作支持 （allow deny log）
if  host_Mod_state == "on" then
	local tb = cjson_safe.decode(host_dict:get(host.."_HostMod")) or {}
	local _action
	for i,v in ipairs(tb) do
		if v.state == "on" then
			if v.action[2] == "uri" and remath(uri,v.uri[1],v.uri[2]) then

				_action = v.action[1]				
				if _action == "deny" then
					Set_count_dict(host.." deny count")
					optl.debug(base_msg,"deny No: "..i,host..".log")
					action_deny()
					break
				elseif _action == "log" then
					Set_count_dict(host.." log count")
					optl.debug(base_msg,"log No: "..i,host..".log")
				elseif _action == "allow" then
					return
				end
				
			elseif v.action[2] == "referer" and remath(referer,v.referer[1],v.referer[2]) and remath(uri,v.uri[1],v.uri[2]) then

				_action = v.action[1]
				if _action == "deny" then
					Set_count_dict(host.." deny count")
					optl.debug(base_msg,"deny No: "..i,host..".log")
					action_deny()
					break
				elseif _action == "log" then
					Set_count_dict(host.." log count")
					optl.debug(base_msg,"log No: "..i,host..".log")
				elseif _action == "allow" then
					return
				end

			elseif v.action[2] == "useragent" and remath(useragent,v.useragent[1],v.useragent[2]) then
				
				_action = v.action[1]
				if _action == "deny" then
					Set_count_dict(host.." deny count")
					optl.debug(base_msg,"deny No: "..i,host..".log")
					action_deny()
					break
				elseif _action == "log" then
					Set_count_dict(host.." log count")
					optl.debug(base_msg,"log No: "..i,host..".log")
				elseif _action == "allow" then
					return
				end

			elseif v.action[2] == "network" and remath(uri,v.uri[1],v.uri[2]) then

				local mod_host_ip = ip.." host_network_Mod No "..i
				local ip_count = limit_ip_dict:get(mod_host_ip)
				if ip_count == nil then
					local pTime =  v.network.pTime or 10
					limit_ip_dict:set(mod_host_ip,1,pTime)
				else
					local maxReqs = v.network.maxReqs or 50
					if ip_count >= maxReqs then
						local blacktime = v.network.blackTime or 10*60
						ip_dict:safe_set(host.."-"..ip,mod_host_ip,blacktime)
						optl.debug(base_msg,"network_Mod  deny No : "..i,host..".log")
						-- network 触发直接拦截
						Set_count_dict(host.." deny count")
						action_deny()
						break
					else
					    limit_ip_dict:incr(mod_host_ip,1)
					end
				end

			end
		end
	end	
end

-- --- STEP 5
-- -- app_Mod 访问控制 （自定义action）
-- -- 目前支持的 deny allow log next rehtml refile relua relua_str
-- 支持 规则组 取反 or/and 连接符
if config_is_on("app_Mod") then
	local app_mod = getDict_Config("app_Mod")
	for i,v in ipairs(app_mod) do
		if v.state == "on" and host_uri_remath(v.hostname,v.uri) then
			
			if v.app_ext == nil or optl.re_app_ext(v.app_ext,base_msg) then

				if v.action[1] == "deny" then
						
					Set_count_dict("app deny count")
					optl.debug(base_msg,"deny No : "..i,"app.log")
					action_deny()
					break

				elseif v.action[1] == "allow" then

					return

				elseif v.action[1] == "next" then
					--- base_msg 中的 remoteIp host referer useragent method uri request_uri ip
					--- 以上是 next 动作可以匹配的http参数
					local check_next = v.action[2]				
					if type(base_msg[check_next]) ~= "table" and remath(base_msg[check_next],v[check_next][1],v[check_next][2]) then
						-- pass 匹配成功 无操作
					else					
						Set_count_dict("app deny count")
						optl.debug(base_msg,"deny No : "..i,"app.log")
						action_deny()
						break
					end				

				elseif v.action[1] == "log" then
					local http_tmp = {}
					http_tmp["headers"] = headers
					http_tmp["query_string"] = query_string
					if method == "POST" then
						http_tmp["post"] = optl.get_post_str()
					end
					optl.debug(base_msg,"log Msg : "..optl.tableTojson(http_tmp),"app.log")

				elseif v.action[1] == "rehtml" then
					optl.sayHtml_ext(v.rehtml,1)
					break

				elseif v.action[1] == "refile" then
					optl.sayFile(config_base.htmlPath..v.refile)
					break

				-- 2016年10月27日 新增 动态执行lua字符串
				elseif v.action[1] == "relua_str" then
					local re_lua_do = loadstring(v.relua_str)
					if re_lua_do() == "break" then
						ngx.exit(200)					
					end

				elseif v.action[1] == "relua" then
					local re_saylua = optl.sayLua(config_base.htmlPath..v.relua)
					if re_saylua == "break" then
						ngx.exit(200)
					end

				elseif v.action[1] == "set" then -- 预留
					
				end 
			
			end
		end
	end
end

-- --- STEP 6
-- -- referer过滤模块
--  动作支持（allow deny log next）
if config_is_on("referer_Mod") then
	local ref_mod = getDict_Config("referer_Mod")
	for i, v in ipairs( ref_mod ) do
		if v.state == "on" and host_uri_remath(v.hostname,v.uri) then

			if v.action == "allow" then
				if remath(referer,v.referer[1],v.referer[2]) then
					return					
				end				
			elseif v.action == "next" then
				if not remath(referer,v.referer[1],v.referer[2]) then
					Set_count_dict("referer deny count")
					optl.debug(base_msg,"deny  No : "..i,"referer.log")
					action_deny()
					break
				end				
			elseif v.action == "log" then
				if remath(referer,v.referer[1],v.referer[2]) then
					Set_count_dict("referer log count")
					optl.debug(base_msg,"log  No : "..i,"referer.log")
				end
			else
				if remath(referer,v.referer[1],v.referer[2]) then
					Set_count_dict("referer deny count")
					optl.debug(base_msg,"deny  No : "..i,"referer.log")
					action_deny()
					break
				end
			end
		end
	end
end

--- STEP 7
-- uri 过滤(黑/白名单/log)
if config_is_on("uri_Mod") then
	local uri_mod = getDict_Config("uri_Mod")
	for i, v in ipairs( uri_mod ) do
		if v.state == "on" and host_uri_remath(v.hostname,v.uri) then

			if v.action == "allow" then --- 跳出后续规则
				return
			elseif v.action ==	"deny" then
				Set_count_dict("uri deny count")
				optl.debug(base_msg,"deny No : "..i,"uri.log")
				action_deny()
				break
			elseif v.action == "log" then
				Set_count_dict("uri log count")
				optl.debug(base_msg,"log No : "..i,"uri.log")
			end
			
		end
	end	
end

--- STEP 8
-- header 过滤(黑名单) [scanner]
if config_is_on("header_Mod") then
	local tb_mod = getDict_Config("header_Mod")
	for i,v in ipairs(tb_mod) do
		if v.state == "on" and host_uri_remath(v.hostname,v.uri) then
			if optl.action_remath("headers",v.header,base_msg) then
				Set_count_dict("header deny count")
			 	optl.debug(base_msg,"deny No : "..i,"header.log")
			 	action_deny()
			 	break
			end
			
		end
	end
end

--- STEP 9
-- useragent(黑、白名单/log记录)
if config_is_on("useragent_Mod") then
	local uagent_mod = getDict_Config("useragent_Mod")
	for i, v in ipairs( uagent_mod ) do
		if v.state == "on" and remath(host,v.hostname[1],v.hostname[2]) then

			if remath(useragent,v.useragent[1],v.useragent[2]) then
				if v.action == "allow" then
					return
				elseif v.action == "log" then
					Set_count_dict("useragent log count")
					optl.debug(base_msg,"log No : "..i,"useragent.log")					
				else
					Set_count_dict("useragent deny count")
					optl.debug(base_msg,"deny No : "..i,"useragent.log")
					action_deny()
					break
				end
			end
			
		end
	end
end

--- STEP 10
-- cookie (黑/白名单/log记录)
if config_is_on("cookie_Mod") and cookie ~= "" then
	local cookie_mod = getDict_Config("cookie_Mod")
	for i, v in ipairs( cookie_mod ) do
		if v.state == "on" and remath(host,v.hostname[1],v.hostname[2]) then

			if remath(cookie,v.cookie[1],v.cookie[2]) then
				if v.action == "deny" then
					Set_count_dict("cookie deny count")
					optl.debug(base_msg,"deny _cookie : "..cookie.." No : "..i,"cookie.log")
					action_deny()
					break
				elseif v.action =="log" then
					Set_count_dict("cookie log count")
					optl.debug(base_msg,"log _cookie : "..cookie.." No : "..i,"cookie.log")
				elseif v.action == "allow" then
					return
				end
			end

		end
	end
end

--- STEP 11
-- args [query_string] (黑/白名单/log记录)
if config_is_on("args_Mod") and query_string ~= "" then
	--debug("args_Mod is on")
	local args_mod = getDict_Config("args_Mod")

	for i,v in ipairs(args_mod) do
		if v.state == "on" and remath(host,v.hostname[1],v.hostname[2]) then
		
			if remath(query_string,v.query_string[1],v.query_string[2]) then
				if v.action == "deny" then
					Set_count_dict("args deny count")
					optl.debug(base_msg,"deny args = "..query_string.." No : "..i,"args.log")
					action_deny()
					break
				elseif v.action == "log" then
					Set_count_dict("args log count")
					optl.debug(base_msg,"log args = "..query_string.." No : "..i,"args.log")							
				elseif v.action == "allow" then
					return							
				end
			end
			
		end
	end	
end

--- STEP 12
-- post (黑/白名单)
if config_is_on("post_Mod") and post_data ~= "" then
	local post_mod = getDict_Config("post_Mod")
	for i,v in ipairs(post_mod) do
		if v.state == "on" and remath(host,v.hostname[1],v.hostname[2]) then

			if remath(post_data,v.post_str[1],v.post_str[2]) then
				if v.action == "deny" then
					Set_count_dict("post deny count")
					optl.debug(base_msg,"deny post : "..post_data.."No : "..i,"post.log")
					action_deny()
					break
				elseif v.action == "log" then
					Set_count_dict("post log count")
					optl.debug(base_msg,"deny post : "..post_data.."No : "..i,"post.log")
				elseif v.action == "allow" then
					return
				end
			end
		end
	end
end


--- STEP 13
-- network_Mod 访问控制
if config_is_on("network_Mod") then
	local tb_networkMod = getDict_Config("network_Mod")
	for i, v in ipairs( tb_networkMod ) do
		if v.state =="on" and host_uri_remath(v.hostname,v.uri) then

			local mod_ip = ip.." network_Mod No "..i
			local ip_count = limit_ip_dict:get(mod_ip)
			if ip_count == nil then
				local pTime =  v.network.pTime or 10
				limit_ip_dict:set(mod_ip,1,pTime)
			else
				local maxReqs = v.network.maxReqs or 50
				if ip_count >= maxReqs then
					local blacktime = v.network.blackTime or 10*60
					if v.hostname[2] == "" then
						if v.hostname[1] == "*" then
							ip_dict:safe_set(ip,mod_ip,blacktime)
						else
							ip_dict:safe_set(host.."-"..ip,mod_ip,blacktime)
						end
					elseif v.hostname[2] == "table" then
						for j,vj in ipairs(v.hostname[1]) do
							ip_dict:safe_set(vj.."-"..ip,mod_ip,blacktime)
						end
					elseif v.hostname[2] == "list" then
						for j,vj in pairs(v.hostname[1]) do
							ip_dict:safe_set(j.."-"..ip,mod_ip,blacktime)
						end
					else
						ip_dict:safe_set(host.."-"..ip,mod_ip,blacktime)
					end
					optl.debug(base_msg,"deny  No : "..i,"network.log")
					action_deny()
					--ngx.say("frist network deny")
					break
				else
				    limit_ip_dict:incr(mod_ip,1)
				end
			end
			
		end
	end
end

--- STEP 14
if config_is_on("replace_Mod") then
	local Replace_Mod = getDict_Config("replace_Mod")
	for i,v in ipairs(Replace_Mod) do
		if v.state =="on" and host_uri_remath(v.hostname,v.uri) then
			ngx_ctx.body_mod = v
			break
		end
	end
end