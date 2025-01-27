local o_template = require("overseer.template")
local overseer = require("overseer")
local harpoon = require("harpoon")

---@class OqtListItem
---@field name string
---@field cmd string[]
---@field _task_id? number

local oqt = {}
local last_cmd_id = nil
---@type HarpoonPartialConfigItem
oqt.harppon_list_config = {
	encode = function(list_item)
		if list_item.value.name == nil or list_item.value.cmd == nil then
			return nil
		end
		local obj = {
			name = list_item.value.name,
			cmd = list_item.value.cmd,
		}
		return vim.json.encode(obj)
	end,

	decode = function(obj_str)
		local obj = vim.json.decode(obj_str)
		return {
			value = obj,
		}
	end,

	display = function(list_item)
		return list_item.value.name
	end,

	-- dont have duplicate names, name will overwrite
	equals = function(list_line_a, list_line_b)
		return list_line_a.value.name == list_line_b.value.name
	end,

	create_list_item = function(_, item)
		-- from ui
		if item ~= nil then
			if type(item) == "string" then
				return {
					value = {
						name = item,
						cmd = item,
					},
				}
			elseif type(item) == "table" then
				-- transform into a list item
				if item.value == nil then
					item = {
						value = item,
					}
				end
				vim.validate({
					name = { item.value.name, "string" },
					cmd = { item.value.name, { "string", "table" } },
				})
				return item
			end
			error("invalid item type")
		end
		error("Cannot create an item with append(nil), use oqt.prompt_new_task()")
	end,

	select = function(list_item, _, _)
		local make_task = function()
			return overseer.new_task({
				name = list_item.value.name,
				cmd = list_item.value.cmd,
				components = { -- required because "default" causes errors for some reason
					{ "display_duration", detail_level = 2 },
					"on_output_summarize",
					"on_exit_set_status",
					"on_complete_notify",
					"on_complete_dispose",
					{
						"on_output_parse",
						parser = {
							-- Put the parser results into the 'diagnostics' field on the task result
							diagnostics = {
								-- Extract fields using lua patterns
								-- To integrate with other components, items in the "diagnostics" result should match
								-- vim's quickfix item format (:help setqflist)
								-- just to trace the output of the traceback and find the routine of it.
								{
									"extract",
									'[:space:]*File "(.*)", line ([0-9]+), in (.*)',
									"filename",
									"lnum",
									"text",
								},
							},
						},
					},
					"on_result_diagnostics",
				},
			})
		end

		local task = nil

		-- task not created yet
		if list_item.value._task_id == nil then
			task = make_task()
		end

		-- task should be created, lets look for it
		if task == nil then
			local tasks = overseer.list_tasks({
				filter = function(t)
					return t.id == list_item.value._task_id
				end,
			})
			if #tasks == 0 then
				-- couldn't find it, let's make one
				task = make_task()
			else
				task = tasks[1]
			end
		end

		-- set the id so we reuse the same task in the future
		list_item.value._task_id = task.id
		task:restart(true)
	end,
}

--- open overseer shell task prompt, add task to list
function oqt.prompt_new_task()
	local tmpl
	o_template.get_by_name("shell", {
		dir = vim.fn.getcwd(),
	}, function(t)
		tmpl = t
	end)
	o_template.build_task_args(tmpl, { prompt = "always", params = {} }, function(task, err)
		if err or task == nil then
			return
		end
		harpoon:list("oqt"):append({
			value = {
				name = task.name,
				cmd = task.cmd,
			},
		})
	end)
end

--- open float output of most recently run task
function oqt.restart_last_task()
	local tasks = overseer.list_tasks({ recent_first = true })
	if #tasks == 0 then
		vim.notify("no recent tasks", vim.log.levels.WARN)
		return
	end

	local task = tasks[1]
	overseer.run_action(task, "restart")
end

--- open float output of most recently run task
function oqt.float_last_task()
	local tasks = overseer.list_tasks({ recent_first = true })
	if #tasks == 0 then
		vim.notify("no recent tasks", vim.log.levels.WARN)
		return
	end

	local task = tasks[1]
	overseer.run_action(task, "open float")
end

--- open float output of task at index i
---@param i number
function oqt.float_task(i, list_name)
	list_name = list_name or "oqt"
	print("Current list name is : " .. list_name)
	local oqt_list = harpoon:list(list_name)
	-- local oqt_list = harpoon:list("oqt")
	if i <= 0 or i > oqt_list:length() then
		vim.notify("index '" .. tostring(i) .. "' is out of bounds for the oqt list", vim.log.levels.ERROR)
		return
	end
	local item = harpoon:list(list_name):get(i)
	-- local item = harpoon:list("oqt"):get(i)

	local task = nil
	if item.value._task_id ~= nil then
		local tasks = overseer.list_tasks({
			filter = function(t)
				return t.id == item.value._task_id
			end,
		})
		if #tasks > 0 then
			task = tasks[1]
		end
	end

	if task == nil then
		vim.notify(
			"could not open float for task at index '" .. tostring(i) .. "' make sure it was run at least once",
			vim.log.levels.WARN
		)
		return
	end

	overseer.run_action(task, "open float")
end

--- setup default keymaps for oqt
function oqt.setup_keymaps()
	vim.keymap.set("n", "<leader>rn", function()
		oqt.prompt_new_task()
	end, { desc = "[R]uner [N]ew " })

	vim.keymap.set("n", "<leader>rv", function()
		harpoon.ui:toggle_quick_menu(harpoon:list("oqt"))
	end, { desc = "[R]uner [V]iew " })

	vim.keymap.set("n", "<leader>rl", function()
		oqt.float_last_task()
	end, { desc = "[R]uner output [L]ast " })

	vim.keymap.set("n", "<leader>rr", function()
		oqt.restart_last_task()
	end, { desc = "Last [R]uner [R]estart " })

	-- set up numeric keymaps: <leader>r1-9 for running tasks
	for i = 1, 9 do
		vim.keymap.set("n", "<leader>r" .. tostring(i), function()
			harpoon:list("oqt"):select(i)
		end, { desc = "[R]uner run " .. tostring(i) })

		vim.keymap.set("n", "<leader>ro" .. tostring(i), function()
			oqt.float_task(i)
		end, { desc = "[R]uner [O]utput " .. tostring(i) })
	end
end

return oqt
