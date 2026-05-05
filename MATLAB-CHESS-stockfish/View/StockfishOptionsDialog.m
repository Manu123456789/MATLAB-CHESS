classdef StockfishOptionsDialog
    % StockfishOptionsDialog
    % ----------------------
    % Modal editor for Stockfish UCI and search options.

    methods (Static)
        function opts = prompt(opts)
            if nargin < 1 || isempty(opts)
                opts = StockfishBot.defaultOptions();
            end
            opts = StockfishBot.normalizeOptions(opts);
            out = opts;

            d = dialog('Name','Stockfish Options', ...
                'Position',[340 120 820 760], ...
                'Resize','off', 'Color',[1 1 1]);

            uicontrol(d, 'Style','text', 'String','Stockfish UCI Options', ...
                'FontSize',15, 'FontWeight','bold', 'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', 'Position',[20 720 300 28]);
            uicontrol(d, 'Style','text', ...
                'String','These values are sent as UCI setoption commands before the game starts.', ...
                'FontSize',9, 'ForegroundColor',[0.35 0.35 0.35], ...
                'BackgroundColor',[1 1 1], 'HorizontalAlignment','left', ...
                'Position',[20 695 780 20]);

            y = 660;
            rowH = 28;
            gap = 6;
            editW = 100;
            labelW = 125;
            x1 = 20; x2 = 285; x3 = 535;

            h.Threads = addEdit('Threads', opts.Threads, x1, y); y = y - rowH;
            h.Hash = addEdit('Hash MB', opts.Hash, x1, y); y = y - rowH;
            h.MultiPV = addEdit('MultiPV', opts.MultiPV, x1, y); y = y - rowH;
            h.SkillLevel = addEdit('Skill Level', opts.SkillLevel, x1, y); y = y - rowH;
            h.MoveOverhead = addEdit('Move Overhead ms', opts.MoveOverhead, x1, y); y = y - rowH;
            h.nodestime = addEdit('nodestime', opts.nodestime, x1, y); y = y - rowH;
            h.UCI_Elo = addEdit('UCI Elo', opts.UCI_Elo, x1, y); y = y - rowH;
            h.SyzygyProbeDepth = addEdit('Syzygy Probe Depth', opts.SyzygyProbeDepth, x1, y); y = y - rowH;
            h.SyzygyProbeLimit = addEdit('Syzygy Probe Limit', opts.SyzygyProbeLimit, x1, y); y = y - rowH;

            y2 = 660;
            h.Ponder = addCheck('Ponder', opts.Ponder, x2, y2); y2 = y2 - rowH;
            h.ClearHash = addCheck('Clear Hash on start', opts.ClearHash, x2, y2); y2 = y2 - rowH;
            h.UCI_Chess960 = addCheck('UCI Chess960', opts.UCI_Chess960, x2, y2); y2 = y2 - rowH;
            h.UCI_LimitStrength = addCheck('UCI Limit Strength', opts.UCI_LimitStrength, x2, y2); y2 = y2 - rowH;
            h.UCI_ShowWDL = addCheck('UCI Show WDL', opts.UCI_ShowWDL, x2, y2); y2 = y2 - rowH;
            h.Syzygy50MoveRule = addCheck('Syzygy 50-move rule', opts.Syzygy50MoveRule, x2, y2); y2 = y2 - rowH;
            h.UseClock = addCheck('Use game clock for go', opts.UseClock, x2, y2); y2 = y2 - rowH;

            y3 = 660;
            h.SearchMode = addPopup('Search Mode', {'movetime','depth','nodes','mate'}, opts.SearchMode, x3, y3); y3 = y3 - rowH;
            h.SearchMoveTimeMs = addEdit('Move time ms', opts.SearchMoveTimeMs, x3, y3); y3 = y3 - rowH;
            h.SearchDepth = addEdit('Depth', opts.SearchDepth, x3, y3); y3 = y3 - rowH;
            h.SearchNodes = addEdit('Nodes', opts.SearchNodes, x3, y3); y3 = y3 - rowH;
            h.SearchMate = addEdit('Mate search', opts.SearchMate, x3, y3); y3 = y3 - rowH;
            h.WhiteIncrementMs = addEdit('White inc ms', opts.WhiteIncrementMs, x3, y3); y3 = y3 - rowH;
            h.BlackIncrementMs = addEdit('Black inc ms', opts.BlackIncrementMs, x3, y3); y3 = y3 - rowH;

            yText = 380;
            h.NumaPolicy = addWideEdit('NumaPolicy', opts.NumaPolicy, yText); yText = yText - rowH;
            h.SyzygyPath = addWideEdit('SyzygyPath', opts.SyzygyPath, yText); yText = yText - rowH;
            h.EvalFile = addWideEdit('EvalFile', opts.EvalFile, yText); yText = yText - rowH;
            h.EvalFileSmall = addWideEdit('EvalFileSmall', opts.EvalFileSmall, yText); yText = yText - rowH;
            h.DebugLogFile = addWideEdit('Debug Log File', opts.DebugLogFile, yText); yText = yText - rowH;

            uicontrol(d, 'Style','text', 'String','Extra setoption lines:', ...
                'FontSize',10, 'BackgroundColor',[1 1 1], 'HorizontalAlignment','left', ...
                'Position',[20 210 180 20]);
            uicontrol(d, 'Style','text', ...
                'String','Use Option Name=value, one per line. For button options, use just Option Name.', ...
                'FontSize',8, 'ForegroundColor',[0.35 0.35 0.35], ...
                'BackgroundColor',[1 1 1], 'HorizontalAlignment','left', ...
                'Position',[190 210 610 20]);
            h.extraSetOptions = uicontrol(d, 'Style','edit', ...
                'String', extraToString(opts.extraSetOptions), ...
                'FontSize',9, 'Max',8, 'Min',0, 'HorizontalAlignment','left', ...
                'Position',[20 100 780 105]);

            uicontrol(d, 'Style','pushbutton', 'String','Defaults', ...
                'FontSize',10, 'Position',[20 25 90 34], ...
                'Callback', @onDefaults);
            uicontrol(d, 'Style','pushbutton', 'String','Cancel', ...
                'FontSize',10, 'Position',[600 25 90 34], ...
                'Callback', @(~,~) delete(d));
            uicontrol(d, 'Style','pushbutton', 'String','OK', ...
                'FontSize',10, 'Position',[710 25 90 34], ...
                'Callback', @onOK);

            uiwait(d);
            opts = out;

            function hEdit = addEdit(label, val, x, yy)
                uicontrol(d, 'Style','text', 'String',label, ...
                    'FontSize',9, 'BackgroundColor',[1 1 1], 'HorizontalAlignment','left', ...
                    'Position',[x yy labelW 20]);
                hEdit = uicontrol(d, 'Style','edit', 'String',num2str(val), ...
                    'FontSize',9, 'HorizontalAlignment','left', ...
                    'Position',[x+labelW yy editW 22]);
            end

            function hCheck = addCheck(label, val, x, yy)
                hCheck = uicontrol(d, 'Style','checkbox', 'String',label, ...
                    'Value',logical(val), 'FontSize',9, 'BackgroundColor',[1 1 1], ...
                    'HorizontalAlignment','left', 'Position',[x yy 210 22]);
            end

            function hPopup = addPopup(label, items, val, x, yy)
                uicontrol(d, 'Style','text', 'String',label, ...
                    'FontSize',9, 'BackgroundColor',[1 1 1], 'HorizontalAlignment','left', ...
                    'Position',[x yy 110 20]);
                idx = find(strcmpi(items, char(val)), 1);
                if isempty(idx); idx = 1; end
                hPopup = uicontrol(d, 'Style','popupmenu', 'String',items, 'Value',idx, ...
                    'FontSize',9, 'Position',[x+110 yy 135 22]);
            end

            function hEdit = addWideEdit(label, val, yy)
                uicontrol(d, 'Style','text', 'String',label, ...
                    'FontSize',9, 'BackgroundColor',[1 1 1], 'HorizontalAlignment','left', ...
                    'Position',[20 yy 120 20]);
                hEdit = uicontrol(d, 'Style','edit', 'String',char(val), ...
                    'FontSize',9, 'HorizontalAlignment','left', ...
                    'Position',[145 yy 655 22]);
            end

            function onDefaults(~,~)
                out = StockfishBot.defaultOptions();
                delete(d);
            end

            function onOK(~,~)
                newOpts = opts;
                newOpts.Threads = readNum(h.Threads, 1);
                newOpts.Hash = readNum(h.Hash, 16);
                newOpts.MultiPV = readNum(h.MultiPV, 1);
                newOpts.SkillLevel = readNum(h.SkillLevel, 20);
                newOpts.MoveOverhead = readNum(h.MoveOverhead, 10);
                newOpts.nodestime = readNum(h.nodestime, 0);
                newOpts.UCI_Elo = readNum(h.UCI_Elo, 1320);
                newOpts.SyzygyProbeDepth = readNum(h.SyzygyProbeDepth, 1);
                newOpts.SyzygyProbeLimit = readNum(h.SyzygyProbeLimit, 7);

                newOpts.Ponder = logical(h.Ponder.Value);
                newOpts.ClearHash = logical(h.ClearHash.Value);
                newOpts.UCI_Chess960 = logical(h.UCI_Chess960.Value);
                newOpts.UCI_LimitStrength = logical(h.UCI_LimitStrength.Value);
                newOpts.UCI_ShowWDL = logical(h.UCI_ShowWDL.Value);
                newOpts.Syzygy50MoveRule = logical(h.Syzygy50MoveRule.Value);
                newOpts.UseClock = logical(h.UseClock.Value);

                items = h.SearchMode.String;
                newOpts.SearchMode = items{h.SearchMode.Value};
                newOpts.SearchMoveTimeMs = readNum(h.SearchMoveTimeMs, 800);
                newOpts.SearchDepth = readNum(h.SearchDepth, 8);
                newOpts.SearchNodes = readNum(h.SearchNodes, 10000);
                newOpts.SearchMate = readNum(h.SearchMate, 3);
                newOpts.WhiteIncrementMs = readNum(h.WhiteIncrementMs, 0);
                newOpts.BlackIncrementMs = readNum(h.BlackIncrementMs, 0);

                newOpts.NumaPolicy = char(h.NumaPolicy.String);
                newOpts.SyzygyPath = char(h.SyzygyPath.String);
                newOpts.EvalFile = char(h.EvalFile.String);
                newOpts.EvalFileSmall = char(h.EvalFileSmall.String);
                newOpts.DebugLogFile = char(h.DebugLogFile.String);
                newOpts.extraSetOptions = stringToLines(h.extraSetOptions.String);

                out = StockfishBot.normalizeOptions(newOpts);
                delete(d);
            end

            function v = readNum(hEdit, fallback)
                v = str2double(hEdit.String);
                if isnan(v); v = fallback; end
            end

            function s = extraToString(extra)
                if isempty(extra)
                    s = '';
                elseif ischar(extra) || isstring(extra)
                    s = char(extra);
                elseif iscell(extra)
                    s = strjoin(cellfun(@char, extra, 'UniformOutput', false), newline);
                else
                    s = '';
                end
            end

            function lines = stringToLines(s)
                if iscell(s)
                    raw = s;
                else
                    raw = regexp(char(s), '\r?\n', 'split');
                end
                lines = {};
                for ii = 1:numel(raw)
                    line = strtrim(char(raw{ii}));
                    if ~isempty(line)
                        lines{end+1} = line; %#ok<AGROW>
                    end
                end
            end
        end
    end
end
