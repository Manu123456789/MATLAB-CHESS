classdef StockfishBot < handle
    % StockfishBot
    % ------------
    % Minimal UCI bridge for playing against Stockfish from the MATLAB GUI.
    % It launches a Stockfish executable, initializes UCI mode, applies
    % selected UCI options, sends the played move list via
    % "position startpos moves ...", then asks for a bounded search using
    % one of the supported "go" limits.

    properties
        enginePath = ''
        options
        process = []
        stdin = []
        stdout = []
        isStarted = false
        lastLines = {}
    end

    methods
        function this = StockfishBot(enginePath, options)
            if nargin >= 1 && ~isempty(enginePath)
                this.enginePath = char(enginePath);
            end
            if nargin < 2 || isempty(options)
                options = StockfishBot.defaultOptions();
            end
            this.options = StockfishBot.normalizeOptions(options);
        end

        function start(this)
            if this.isStarted && ~isempty(this.process)
                try
                    if this.process.isAlive(); return; end
                catch
                end
            end
            if isempty(this.enginePath)
                error('StockfishBot:MissingEnginePath', 'Stockfish executable path is empty.');
            end
            if exist(this.enginePath, 'file') ~= 2
                error('StockfishBot:MissingEnginePath', 'Stockfish executable was not found:\n%s', this.enginePath);
            end

            try
                cmd = javaArray('java.lang.String', 1);
                cmd(1) = java.lang.String(this.enginePath);
                pb = java.lang.ProcessBuilder(cmd);
                pb.redirectErrorStream(true);
                this.process = pb.start();
                this.stdin = java.io.BufferedWriter(java.io.OutputStreamWriter(this.process.getOutputStream()));
                this.stdout = java.io.BufferedReader(java.io.InputStreamReader(this.process.getInputStream()));
            catch err
                error('StockfishBot:LaunchFailed', 'Could not launch Stockfish:\n%s', err.message);
            end

            this.isStarted = true;
            this.sendLine('uci');
            this.waitForToken('uciok', this.options.uciTimeoutSec);
            this.applyUciOptions();
            this.newGame();
        end

        function newGame(this)
            this.ensureStarted();
            this.sendLine('ucinewgame');
            this.waitReady();
        end

        function waitReady(this)
            this.ensureStarted();
            this.sendLine('isready');
            this.waitForToken('readyok', this.options.readyTimeoutSec);
        end

        function mv = bestMove(this, history, timerState)
            if nargin < 3
                timerState = [];
            end
            moveList = this.historyToUciMoveList(history);
            if isempty(moveList)
                positionCommand = 'position startpos';
            else
                positionCommand = ['position startpos moves ' strjoin(moveList, ' ')];
            end
            mv = this.bestMoveFromPositionCommand(positionCommand, timerState);
        end

        function mv = bestMoveFromFen(this, fen, timerState)
            if nargin < 3
                timerState = [];
            end
            fen = strtrim(char(fen));
            if isempty(fen)
                error('StockfishBot:MissingFen', 'FEN string is empty.');
            end
            mv = this.bestMoveFromPositionCommand(['position fen ' fen], timerState);
        end

        function mv = bestMoveFromPositionCommand(this, positionCommand, timerState)
            if nargin < 3
                timerState = [];
            end
            this.ensureStarted();

            % Do not let leftover output from a previous analysis poison the
            % next request. This matters in the review UI, where the user may
            % analyze several unrelated FEN positions one after another.
            this.flushAvailableOutput();

            this.sendLine(char(positionCommand));
            this.waitReady();
            this.flushAvailableOutput();
            this.sendLine(this.goCommand(timerState));

            lines = this.waitForToken('bestmove', this.options.searchTimeoutSec);
            pause(0.02);
            tail = this.flushAvailableOutput();
            if ~isempty(tail)
                lines = [lines tail]; %#ok<AGROW>
            end
            this.lastLines = lines;
            mv = StockfishBot.parseBestMoveLine(lines);
            mv.pvs = StockfishBot.parsePrincipalVariations(lines);
        end

        function quit(this)
            try
                if this.isStarted && ~isempty(this.stdin)
                    this.sendLine('quit');
                end
            catch
            end
            try
                if ~isempty(this.process)
                    this.process.destroy();
                end
            catch
            end
            this.isStarted = false;
            this.process = [];
            this.stdin = [];
            this.stdout = [];
        end

        function delete(this)
            this.quit();
        end
    end

    methods (Access = private)
        function ensureStarted(this)
            if ~this.isStarted
                this.start();
                return;
            end
            try
                if isempty(this.process) || ~this.process.isAlive()
                    this.isStarted = false;
                    this.start();
                end
            catch
            end
        end

        function sendLine(this, s)
            this.stdin.write([char(s) char(10)]);
            this.stdin.flush();
        end

        function lines = flushAvailableOutput(this)
            lines = {};
            try
                if isempty(this.stdout)
                    return;
                end
                while this.stdout.ready()
                    ln = this.stdout.readLine();
                    if isempty(ln)
                        break;
                    end
                    lines{end+1} = char(ln); %#ok<AGROW>
                end
            catch
                lines = {};
            end
        end

        function lines = waitForToken(this, token, timeoutSec)
            if nargin < 3 || isempty(timeoutSec)
                timeoutSec = 10;
            end
            lines = {};
            t0 = tic;
            while toc(t0) < timeoutSec
                try
                    if this.stdout.ready()
                        ln = this.stdout.readLine();
                        if isempty(ln)
                            pause(0.01);
                            continue;
                        end
                        line = char(ln);
                        lines{end+1} = line; %#ok<AGROW>
                        if contains(line, token)
                            return;
                        end
                    else
                        pause(0.01);
                    end
                catch err
                    error('StockfishBot:ReadFailed', 'Could not read Stockfish output:\n%s', err.message);
                end
            end
            error('StockfishBot:Timeout', 'Timed out waiting for Stockfish token "%s".', token);
        end

        function applyUciOptions(this)
            opts = this.options;
            setSpin('Threads', opts.Threads);
            setSpin('Hash', opts.Hash);
            setSpin('MultiPV', opts.MultiPV);
            setString('NumaPolicy', opts.NumaPolicy);
            setCheck('Ponder', opts.Ponder);
            setSpin('Skill Level', opts.SkillLevel);
            setSpin('Move Overhead', opts.MoveOverhead);
            setSpin('nodestime', opts.nodestime);
            setCheck('UCI_Chess960', opts.UCI_Chess960);
            setCheck('UCI_LimitStrength', opts.UCI_LimitStrength);
            setSpin('UCI_Elo', opts.UCI_Elo);
            setCheck('UCI_ShowWDL', opts.UCI_ShowWDL);
            setString('SyzygyPath', opts.SyzygyPath);
            setSpin('SyzygyProbeDepth', opts.SyzygyProbeDepth);
            setCheck('Syzygy50MoveRule', opts.Syzygy50MoveRule);
            setSpin('SyzygyProbeLimit', opts.SyzygyProbeLimit);
            setString('EvalFile', opts.EvalFile);
            setString('EvalFileSmall', opts.EvalFileSmall);
            setString('Debug Log File', opts.DebugLogFile);

            if opts.ClearHash
                this.sendLine('setoption name Clear Hash');
            end

            if isfield(opts, 'extraSetOptions') && ~isempty(opts.extraSetOptions)
                extra = opts.extraSetOptions;
                if ischar(extra) || isstring(extra)
                    extra = regexp(char(extra), '\r?\n', 'split');
                end
                for k = 1:numel(extra)
                    line = strtrim(char(extra{k}));
                    if isempty(line); continue; end
                    eq = strfind(line, '=');
                    if isempty(eq)
                        this.sendLine(['setoption name ' line]);
                    else
                        name = strtrim(line(1:eq(1)-1));
                        val  = strtrim(line(eq(1)+1:end));
                        if isempty(val)
                            this.sendLine(['setoption name ' name]);
                        else
                            this.sendLine(['setoption name ' name ' value ' val]);
                        end
                    end
                end
            end

            this.waitReady();

            function setSpin(name, val)
                if isempty(val); return; end
                this.sendLine(sprintf('setoption name %s value %d', name, round(double(val))));
            end
            function setCheck(name, val)
                if isempty(val); return; end
                if logical(val); s = 'true'; else; s = 'false'; end
                this.sendLine(sprintf('setoption name %s value %s', name, s));
            end
            function setString(name, val)
                if isempty(val); return; end
                val = strtrim(char(val));
                if isempty(val); return; end
                this.sendLine(sprintf('setoption name %s value %s', name, val));
            end
        end

        function cmd = goCommand(this, timerState)
            opts = this.options;
            if opts.UseClock && nargin >= 2 && ~isempty(timerState) && isstruct(timerState) ...
                    && isfield(timerState, 'enabled') && timerState.enabled
                w = max(0, round(double(timerState.whiteRemainingSec) * 1000));
                b = max(0, round(double(timerState.blackRemainingSec) * 1000));
                wi = max(0, round(double(opts.WhiteIncrementMs)));
                bi = max(0, round(double(opts.BlackIncrementMs)));
                cmd = sprintf('go wtime %d btime %d winc %d binc %d', w, b, wi, bi);
                return;
            end

            mode = lower(strtrim(char(opts.SearchMode)));
            switch mode
                case 'depth'
                    cmd = sprintf('go depth %d', max(1, round(double(opts.SearchDepth))));
                case 'nodes'
                    cmd = sprintf('go nodes %d', max(1, round(double(opts.SearchNodes))));
                case 'mate'
                    cmd = sprintf('go mate %d', max(1, round(double(opts.SearchMate))));
                otherwise
                    cmd = sprintf('go movetime %d', max(1, round(double(opts.SearchMoveTimeMs))));
            end
        end

        function moveList = historyToUciMoveList(~, history)
            moveList = {};
            if isempty(history); return; end
            if ~iscell(history)
                if isstruct(history)
                    history = arrayfun(@(x) x, history, 'UniformOutput', false);
                else
                    return;
                end
            end
            for k = 1:numel(history)
                mv = history{k};
                if ~isstruct(mv) || ~isfield(mv, 'from') || ~isfield(mv, 'to')
                    continue;
                end
                from = double(mv.from(:).');
                to   = double(mv.to(:).');
                if numel(from) ~= 2 || numel(to) ~= 2
                    continue;
                end
                fromRank = from(1); fromFile = from(2);
                toRank   = to(1);   toFile   = to(2);
                if any([fromRank fromFile toRank toFile] < 1) || any([fromRank fromFile toRank toFile] > 8)
                    continue;
                end
                u = sprintf('%c%d%c%d', char('a' + fromFile - 1), fromRank, char('a' + toFile - 1), toRank);
                if isfield(mv, 'promotion') && logical(mv.promotion) && isfield(mv, 'piece') && ~isempty(mv.piece)
                    p = lower(char(mv.piece));
                    p = p(1);
                    if any(p == 'qrbn')
                        u = [u p]; %#ok<AGROW>
                    end
                end
                moveList{end+1} = u; %#ok<AGROW>
            end
        end
    end

    methods (Static)
        function opts = defaultOptions()
            opts = struct();
            opts.Threads = 1;
            opts.Hash = 16;
            opts.MultiPV = 1;
            opts.NumaPolicy = 'auto';
            opts.ClearHash = false;
            opts.Ponder = false;
            opts.SkillLevel = 20;
            opts.MoveOverhead = 10;
            opts.nodestime = 0;
            opts.UCI_Chess960 = false;
            opts.UCI_LimitStrength = false;
            opts.UCI_Elo = 1320;
            opts.UCI_ShowWDL = false;
            opts.SyzygyPath = '';
            opts.SyzygyProbeDepth = 1;
            opts.Syzygy50MoveRule = true;
            opts.SyzygyProbeLimit = 7;
            opts.EvalFile = '';
            opts.EvalFileSmall = '';
            opts.DebugLogFile = '';
            opts.extraSetOptions = {};

            % Search controls. These are GUI-level controls for the UCI
            % "go" command, not Stockfish setoption values.
            opts.SearchMode = 'movetime';
            opts.SearchMoveTimeMs = 800;
            opts.SearchDepth = 8;
            opts.SearchNodes = 10000;
            opts.SearchMate = 3;
            opts.UseClock = false;
            opts.WhiteIncrementMs = 0;
            opts.BlackIncrementMs = 0;

            opts.uciTimeoutSec = 10;
            opts.readyTimeoutSec = 10;
            opts.searchTimeoutSec = 60;
        end

        function opts = normalizeOptions(opts)
            defaults = StockfishBot.defaultOptions();
            if nargin < 1 || isempty(opts) || ~isstruct(opts)
                opts = defaults;
                return;
            end
            fn = fieldnames(defaults);
            for k = 1:numel(fn)
                if ~isfield(opts, fn{k}) || isempty(opts.(fn{k}))
                    opts.(fn{k}) = defaults.(fn{k});
                end
            end
        end

        function pvs = parsePrincipalVariations(lines)
            emptyPv = struct('multipv', {}, 'depth', {}, 'scoreType', {}, ...
                             'scoreValue', {}, 'firstMove', {}, 'line', {});
            pvs = emptyPv;
            if isempty(lines)
                return;
            end

            pvMap = containers.Map('KeyType','char','ValueType','any');
            for k = 1:numel(lines)
                line = strtrim(char(lines{k}));
                if isempty(regexp(line, '^info\s', 'once')) || isempty(strfind(line, ' pv '))
                    continue;
                end

                depth = NaN;
                tok = regexp(line, 'depth\s+(\d+)', 'tokens', 'once');
                if ~isempty(tok); depth = str2double(tok{1}); end

                multipv = 1;
                tok = regexp(line, 'multipv\s+(\d+)', 'tokens', 'once');
                if ~isempty(tok); multipv = str2double(tok{1}); end

                scoreType = '';
                scoreValue = NaN;
                tok = regexp(line, 'score\s+(cp|mate)\s+(-?\d+)', 'tokens', 'once');
                if ~isempty(tok)
                    scoreType = tok{1};
                    scoreValue = str2double(tok{2});
                end

                tok = regexp(line, '\spv\s+([^\r\n]+)$', 'tokens', 'once');
                if isempty(tok)
                    continue;
                end
                pvMoves = strtrim(tok{1});
                pieces = regexp(pvMoves, '\s+', 'split');
                if isempty(pieces) || isempty(pieces{1})
                    continue;
                end

                pv = struct();
                pv.multipv = multipv;
                pv.depth = depth;
                pv.scoreType = scoreType;
                pv.scoreValue = scoreValue;
                pv.firstMove = pieces{1};
                pv.line = pvMoves;
                pvMap(sprintf('%03d', multipv)) = pv;
            end

            if pvMap.Count == 0
                return;
            end
            keysList = sort(keys(pvMap));
            for k = 1:numel(keysList)
                pvs(end+1) = pvMap(keysList{k}); %#ok<AGROW>
            end
        end

        function opts = fullStrengthAnalysisOptions(baseOptions)
            if nargin < 1 || isempty(baseOptions) || ~isstruct(baseOptions)
                opts = StockfishBot.defaultOptions();
            else
                opts = StockfishBot.normalizeOptions(baseOptions);
            end
            opts.UCI_LimitStrength = false;
            opts.SkillLevel = 20;
            opts.MultiPV = max(3, round(double(opts.MultiPV)));
            opts.Ponder = false;
            opts.SearchMode = 'depth';
            opts.SearchDepth = max(16, round(double(opts.SearchDepth)));
            opts.SearchMoveTimeMs = max(2500, round(double(opts.SearchMoveTimeMs)));
            opts.searchTimeoutSec = max(120, round(double(opts.searchTimeoutSec)));
        end

        function mv = parseBestMoveLine(lines)
            mv = struct('uci','', 'srcFile',[], 'srcRank',[], 'dstFile',[], 'dstRank',[], 'promotion','', 'pvs', []);
            if isempty(lines)
                return;
            end
            best = '';
            for k = numel(lines):-1:1
                line = char(lines{k});
                if startsWith(strtrim(line), 'bestmove')
                    best = strtrim(line);
                    break;
                end
            end
            if isempty(best)
                return;
            end
            tok = regexp(best, 'bestmove\s+([a-h][1-8][a-h][1-8][qrbn]?)', 'tokens', 'once');
            if isempty(tok)
                return;
            end
            u = tok{1};
            mv.uci = u;
            mv.srcFile = double(u(1)) - double('a') + 1;
            mv.srcRank = str2double(u(2));
            mv.dstFile = double(u(3)) - double('a') + 1;
            mv.dstRank = str2double(u(4));
            if numel(u) >= 5
                mv.promotion = upper(u(5));
            end
        end
    end
end
