define [
	"base"
	"ace/ace"
	"ide/human-readable-logs/HumanReadableLogs"
	"libs/bib-log-parser"
], (App, Ace, HumanReadableLogs, BibLogParser) ->
	App.controller "PdfController", ($scope, $http, ide, $modal, synctex, event_tracking, localStorage) ->

		# enable per-user containers by default
		perUserCompile = true
		autoCompile = true

		# pdf.view = uncompiled | pdf | errors
		$scope.pdf.view = if $scope?.pdf?.url then 'pdf' else 'uncompiled'
		$scope.shouldShowLogs = false
		$scope.wikiEnabled = window.wikiEnabled;

		# log hints tracking
		trackLogHintsFeedback = (isPositive, hintId) ->
			event_tracking.send 'log-hints', (if isPositive then 'feedback-positive' else 'feedback-negative'), hintId

		$scope.trackLogHintsPositiveFeedback = (hintId) -> trackLogHintsFeedback true, hintId
		$scope.trackLogHintsNegativeFeedback = (hintId) -> trackLogHintsFeedback false, hintId

		if ace.require("ace/lib/useragent").isMac
			$scope.modifierKey = "Cmd"
		else
			$scope.modifierKey = "Ctrl"

		# utility for making a query string from a hash, could use jquery $.param
		createQueryString = (args) ->
			qs_args = ("#{k}=#{v}" for k, v of args)
			if qs_args.length then "?" + qs_args.join("&") else ""

		$scope.stripHTMLFromString = (htmlStr) ->
   			tmp = document.createElement("DIV")
   			tmp.innerHTML = htmlStr
   			return tmp.textContent || tmp.innerText || ""

		$scope.$on "project:joined", () ->
			return if !autoCompile
			autoCompile = false
			$scope.recompile(isAutoCompile: true)
			$scope.hasPremiumCompile = $scope.project.features.compileGroup == "priority"

		$scope.$on "pdf:error:display", () ->
			$scope.pdf.view = 'errors'
			$scope.pdf.renderingError = true

		$scope.draft = localStorage("draft:#{$scope.project_id}") or false
		$scope.$watch "draft", (new_value, old_value) ->
			if new_value? and old_value != new_value
				localStorage("draft:#{$scope.project_id}", new_value)

		sendCompileRequest = (options = {}) ->
			url = "/project/#{$scope.project_id}/compile"
			params = {}
			if options.isAutoCompile
				params["auto_compile"]=true
			return $http.post url, {
				rootDoc_id: options.rootDocOverride_id or null
				draft: $scope.draft
				_csrf: window.csrfToken
			}, {params: params}

		parseCompileResponse = (response) ->		

			# Reset everything
			$scope.pdf.error      = false
			$scope.pdf.timedout   = false
			$scope.pdf.failure    = false
			$scope.pdf.url        = null
			$scope.pdf.clsiMaintenance = false
			$scope.pdf.tooRecentlyCompiled = false
			$scope.pdf.renderingError = false
			$scope.pdf.projectTooLarge = false

			# make a cache to look up files by name
			fileByPath = {}
			if response?.outputFiles?
				for file in response?.outputFiles
					fileByPath[file.path] = file

			if response.status == "timedout"
				$scope.pdf.view = 'errors'
				$scope.pdf.timedout = true
			else if response.status == "autocompile-backoff"
				$scope.pdf.view = 'uncompiled'
			else if response.status == "project-too-large"
				$scope.pdf.view = 'errors'
				$scope.pdf.projectTooLarge = true
			else if response.status == "failure"
				$scope.pdf.view = 'errors'
				$scope.pdf.failure = true
				$scope.shouldShowLogs = true
				fetchLogs(fileByPath['output.log'], fileByPath['output.blg'])
			else if response.status == 'clsi-maintenance'
				$scope.pdf.view = 'errors'
				$scope.pdf.clsiMaintenance = true
			else if response.status == "too-recently-compiled"
				$scope.pdf.view = 'errors'
				$scope.pdf.tooRecentlyCompiled = true
			else if response.status == "validation-problems"
				$scope.pdf.view = "validation-problems"
				$scope.pdf.validation = response.validationProblems
			else if response.status == "success"
				$scope.pdf.view = 'pdf'
				$scope.shouldShowLogs = false

				# prepare query string
				qs = {}
				# define the base url. if the pdf file has a build number, pass it to the clsi in the url
				if fileByPath['output.pdf']?.url?
					$scope.pdf.url = fileByPath['output.pdf'].url
				else if fileByPath['output.pdf']?.build?
					build = fileByPath['output.pdf'].build
					$scope.pdf.url = "/project/#{$scope.project_id}/build/#{build}/output/output.pdf"
				else
					$scope.pdf.url = "/project/#{$scope.project_id}/output/output.pdf"
				# check if we need to bust cache (build id is unique so don't need it in that case)
				if not fileByPath['output.pdf']?.build?
					qs.cache_bust = "#{Date.now()}"
				# add a query string parameter for the compile group
				if response.compileGroup?
					$scope.pdf.compileGroup = response.compileGroup
					qs.compileGroup = "#{$scope.pdf.compileGroup}"
				if response.clsiServerId?
					qs.clsiserverid = response.clsiServerId
					ide.clsiServerId = response.clsiServerId
				# convert the qs hash into a query string and append it
				$scope.pdf.qs = createQueryString qs
				$scope.pdf.url += $scope.pdf.qs
				# Save all downloads as files
				qs.popupDownload = true
				$scope.pdf.downloadUrl = "/project/#{$scope.project_id}/output/output.pdf" + createQueryString(qs)

				fetchLogs(fileByPath['output.log'], fileByPath['output.blg'])

			IGNORE_FILES = ["output.fls", "output.fdb_latexmk"]
			$scope.pdf.outputFiles = []

			if !response.outputFiles?
				return
			for file in response.outputFiles
				if IGNORE_FILES.indexOf(file.path) == -1
					# Turn 'output.blg' into 'blg file'.
					if file.path.match(/^output\./)
						file.name = "#{file.path.replace(/^output\./, "")} file"
					else
						file.name = file.path
					qs = {}
					if response.clsiServerId?
						qs.clsiserverid = response.clsiServerId
					file.url = "/project/#{project_id}/output/#{file.path}" +	createQueryString qs
					$scope.pdf.outputFiles.push file


		fetchLogs = (logFile, blgFile) ->

			getFile = (name, file) ->
				opts =
					method:"GET"
					params:
						clsiserverid:ide.clsiServerId
				if file?.url?  # FIXME clean this up when we have file.urls out consistently
					opts.url = file.url
				else if file?.build?
					opts.url = "/project/#{$scope.project_id}/build/#{file.build}/output/#{name}"
				else
					opts.url = "/project/#{$scope.project_id}/output/#{name}"
				return $http(opts)

			# accumulate the log entries
			logEntries =
				all: []
				errors: []
				warnings: []

			accumulateResults = (newEntries) ->
				for key in ['all', 'errors', 'warnings']
					logEntries[key] = logEntries[key].concat newEntries[key]

			# use the parsers for each file type
			processLog = (log) ->
				$scope.pdf.rawLog = log
				{errors, warnings, typesetting} = HumanReadableLogs.parse(log, ignoreDuplicates: true)
				all = [].concat errors, warnings, typesetting
				accumulateResults {all, errors, warnings}

			processBiber = (log) ->
				{errors, warnings} = BibLogParser.parse(log, {})
				all = [].concat errors, warnings
				accumulateResults {all, errors, warnings}

			# output the results
			handleError = () ->
				$scope.pdf.logEntries = []
				$scope.pdf.rawLog = ""

			annotateFiles = () ->
				$scope.pdf.logEntries = logEntries
				$scope.pdf.logEntryAnnotations = {}
				for entry in logEntries.all
					if entry.file?
						entry.file = normalizeFilePath(entry.file)
						entity = ide.fileTreeManager.findEntityByPath(entry.file)
						if entity?
							$scope.pdf.logEntryAnnotations[entity.id] ||= []
							$scope.pdf.logEntryAnnotations[entity.id].push {
								row: entry.line - 1
								type: if entry.level == "error" then "error" else "warning"
								text: entry.message
							}

			# retrieve the logfile and process it
			response = getFile('output.log', logFile)
				.success processLog
				.error handleError

			if blgFile?	# retrieve the blg file if present
				response.success () ->
					getFile('output.blg', blgFile)
						# ignore errors in biber file
						.success processBiber
						# display the combined result
						.then annotateFiles
			else # otherwise just display the result
				response.success annotateFiles

		getRootDocOverride_id = () ->
			doc = ide.editorManager.getCurrentDocValue()
			return null if !doc?
			for line in doc.split("\n")
				match = line.match /^[^%]*\\documentclass/
				if match
					return ide.editorManager.getCurrentDocId()
			return null

		normalizeFilePath = (path) ->
			path = path.replace(/^(.*)\/compiles\/[0-9a-f]{24}(-[0-9a-f]{24})?\/(\.\/)?/, "")
			path = path.replace(/^\/compile\//, "")

			rootDocDirname = ide.fileTreeManager.getRootDocDirname()
			if rootDocDirname?
				path = path.replace(/^\.\//, rootDocDirname + "/")

			return path

		$scope.recompile = (options = {}) ->
			return if $scope.pdf.compiling
			$scope.pdf.compiling = true

			ide.$scope.$broadcast("flush-changes")

			options.rootDocOverride_id = getRootDocOverride_id()

			sendCompileRequest(options)
				.success (data) ->
					$scope.pdf.view = "pdf"
					$scope.pdf.compiling = false
					parseCompileResponse(data)
				.error () ->
					$scope.pdf.compiling = false
					$scope.pdf.renderingError = false
					$scope.pdf.error = true
					$scope.pdf.view = 'errors'

		# This needs to be public.
		ide.$scope.recompile = $scope.recompile

		$scope.clearCache = () ->
			$http {
				url: "/project/#{$scope.project_id}/output"
				method: "DELETE"
				params:
					clsiserverid:ide.clsiServerId
				headers:
					"X-Csrf-Token": window.csrfToken
			}

		$scope.toggleLogs = () ->
			$scope.shouldShowLogs = !$scope.shouldShowLogs

		$scope.showPdf = () ->
			$scope.pdf.view = "pdf"
			$scope.shouldShowLogs = false

		$scope.toggleRawLog = () ->
			$scope.pdf.showRawLog = !$scope.pdf.showRawLog

		$scope.openClearCacheModal = () ->
			modalInstance = $modal.open(
				templateUrl: "clearCacheModalTemplate"
				controller: "ClearCacheModalController"
				scope: $scope
			)

		$scope.syncToCode = (position) ->
			synctex
				.syncToCode(position)
				.then (data) ->
					{doc, line} = data
					ide.editorManager.openDoc(doc, gotoLine: line)

		$scope.switchToFlatLayout = () ->
			$scope.ui.pdfLayout = 'flat'
			$scope.ui.view = 'pdf'
			ide.localStorage "pdf.layout", "flat"

		$scope.switchToSideBySideLayout = () ->
			$scope.ui.pdfLayout = 'sideBySide'
			$scope.ui.view = 'editor'
			localStorage "pdf.layout", "split"

		if pdfLayout = localStorage("pdf.layout")
			$scope.switchToSideBySideLayout() if pdfLayout == "split"
			$scope.switchToFlatLayout() if pdfLayout == "flat"
		else
			$scope.switchToSideBySideLayout()

		$scope.startFreeTrial = (source) ->
			ga?('send', 'event', 'subscription-funnel', 'compile-timeout', source)
			window.open("/user/subscription/new?planCode=student_free_trial_7_days")
			$scope.startedFreeTrial = true

	App.factory "synctex", ["ide", "$http", "$q", (ide, $http, $q) ->
		# enable per-user containers by default
		perUserCompile = true

		synctex =
			syncToPdf: (cursorPosition) ->
				deferred = $q.defer()

				doc_id = ide.editorManager.getCurrentDocId()
				if !doc_id?
					deferred.reject()
					return deferred.promise
				doc = ide.fileTreeManager.findEntityById(doc_id)
				if !doc?
					deferred.reject()
					return deferred.promise
				path = ide.fileTreeManager.getEntityPath(doc)
				if !path?
					deferred.reject()
					return deferred.promise

				# If the root file is folder/main.tex, then synctex sees the
				# path as folder/./main.tex
				rootDocDirname = ide.fileTreeManager.getRootDocDirname()
				if rootDocDirname? and rootDocDirname != ""
					path = path.replace(RegExp("^#{rootDocDirname}"), "#{rootDocDirname}/.")

				{row, column} = cursorPosition

				$http({
						url: "/project/#{ide.project_id}/sync/code",
						method: "GET",
						params: {
							file: path
							line: row + 1
							column: column
							clsiserverid:ide.clsiServerId
						}
					})
					.success (data) ->
						deferred.resolve(data.pdf or [])
					.error (error) ->
						deferred.reject(error)

				return deferred.promise

			syncToCode: (position, options = {}) ->
				deferred = $q.defer()
				if !position?
					deferred.reject()
					return deferred.promise

				# FIXME: this actually works better if it's halfway across the
				# page (or the visible part of the page). Synctex doesn't
				# always find the right place in the file when the point is at
				# the edge of the page, it sometimes returns the start of the
				# next paragraph instead.
				h = position.offset.left

				# Compute the vertical position to pass to synctex, which
				# works with coordinates increasing from the top of the page
				# down.  This matches the browser's DOM coordinate of the
				# click point, but the pdf position is measured from the
				# bottom of the page so we need to invert it.
				if options.fromPdfPosition and position.pageSize?.height?
					v = (position.pageSize.height - position.offset.top) or 0 # measure from pdf point (inverted)
				else
					v = position.offset.top or 0 # measure from html click position

				# It's not clear exactly where we should sync to if it wasn't directly
				# clicked on, but a little bit down from the very top seems best.
				if options.includeVisualOffset
					v += 72 # use the same value as in pdfViewer highlighting visual offset

				$http({
						url: "/project/#{ide.project_id}/sync/pdf",
						method: "GET",
						params: {
							page: position.page + 1
							h: h.toFixed(2)
							v: v.toFixed(2)
							clsiserverid:ide.clsiServerId
						}
					})
					.success (data) ->
						if data.code? and data.code.length > 0
							doc = ide.fileTreeManager.findEntityByPath(data.code[0].file)
							return if !doc?
							deferred.resolve({doc: doc, line: data.code[0].line})
					.error (error) ->
						deferred.reject(error)

				return deferred.promise

		return synctex
	]

	App.controller "PdfSynctexController", ["$scope", "synctex", "ide", ($scope, synctex, ide) ->
		@cursorPosition = null
		ide.$scope.$on "cursor:editor:update", (event, @cursorPosition) =>

		$scope.syncToPdf = () =>
			return if !@cursorPosition?
			synctex
				.syncToPdf(@cursorPosition)
				.then (highlights) ->
					$scope.pdf.highlights = highlights

		$scope.syncToCode = () ->
			synctex
				.syncToCode($scope.pdf.position, includeVisualOffset: true, fromPdfPosition: true)
				.then (data) ->
					{doc, line} = data
					ide.editorManager.openDoc(doc, gotoLine: line)
	]

	App.controller "PdfLogEntryController", ["$scope", "ide", ($scope, ide) ->
		$scope.openInEditor = (entry) ->
			entity = ide.fileTreeManager.findEntityByPath(entry.file)
			return if !entity? or entity.type != "doc"
			if entry.line?
				line = entry.line
			ide.editorManager.openDoc(entity, gotoLine: line)
	]

	App.controller 'ClearCacheModalController', ["$scope", "$modalInstance", ($scope, $modalInstance) ->
		$scope.state =
			inflight: false

		$scope.clear = () ->
			$scope.state.inflight = true
			$scope
				.clearCache()
				.then () ->
					$scope.state.inflight = false
					$modalInstance.close()

		$scope.cancel = () ->
			$modalInstance.dismiss('cancel')
	]
