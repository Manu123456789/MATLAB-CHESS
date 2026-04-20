classdef GameState
    % GameState
    % ---------
    % Serializable snapshot of a chess game. This is the single source of
    % truth that gets written to / read from disk for networked play.
    
    methods (Static)
        function state = initial(hostColor, timerEnabled, timerMinutes)
            if nargin < 2; timerEnabled = false; end
            if nargin < 3 || isempty(timerMinutes); timerMinutes = 10; end
            state = struct();
            state.schemaVersion = 3;
            state.gameId        = GameState.newGameId();
            state.hostColor     = hostColor;
            state.createdAt     = GameState.nowISO();
            state.updatedAt     = state.createdAt;
            state.board = {
                'RNBQKBNR'
                'PPPPPPPP'
                '........'
                '........'
                '........'
                '........'
                'pppppppp'
                'rnbqkbnr'
            };
            state.moved          = false(8,8);
            state.turn           = 'w';
            state.moveNumber     = 1;
            state.halfmoveClock  = 0;
            state.lastMove       = [];
            state.history        = {};
            state.status         = 'active';
            state.enPassantInfo  = [];
            state.timer          = GameState.makeTimerState(timerEnabled, timerMinutes);
            if hostColor == 'w'
                state.timer.whiteOpened = true;
            else
                state.timer.blackOpened = true;
            end
        end
        
        function timerState = makeTimerState(timerEnabled, timerMinutes)
            if nargin < 1 || isempty(timerEnabled); timerEnabled = false; end
            if nargin < 2 || isempty(timerMinutes); timerMinutes = 10; end
            initialSeconds = round(double(timerMinutes) * 60);
            timerState = struct( ...
                'enabled', logical(timerEnabled), ...
                'initialSeconds', initialSeconds, ...
                'whiteRemainingSec', initialSeconds, ...
                'blackRemainingSec', initialSeconds, ...
                'running', false, ...
                'paused', false, ...
                'pausedBy', '', ...
                'activeColor', 'w', ...
                'startedAt', '', ...
                'expiredColor', '', ...
                'whiteOpened', false, ...
                'blackOpened', false);
        end
        
        function timerState = normalizeTimerState(timerState)
            if nargin < 1 || isempty(timerState) || ~isstruct(timerState)
                timerState = GameState.makeTimerState(false, 10);
                return;
            end
            defaults = GameState.makeTimerState(false, 10);
            fn = fieldnames(defaults);
            for k = 1:numel(fn)
                if ~isfield(timerState, fn{k}) || isempty(timerState.(fn{k}))
                    timerState.(fn{k}) = defaults.(fn{k});
                end
            end
            timerState.enabled = logical(timerState.enabled);
            timerState.running = logical(timerState.running);
            timerState.paused = logical(timerState.paused);
            timerState.initialSeconds = double(timerState.initialSeconds);
            timerState.whiteRemainingSec = double(timerState.whiteRemainingSec);
            timerState.blackRemainingSec = double(timerState.blackRemainingSec);
            if isstring(timerState.activeColor) && ~isempty(timerState.activeColor)
                timerState.activeColor = char(timerState.activeColor);
            end
            if isempty(timerState.activeColor)
                timerState.activeColor = 'w';
            else
                timerState.activeColor = timerState.activeColor(1);
            end
            for fld = {'startedAt','expiredColor','pausedBy'}
                f = fld{1};
                if isstring(timerState.(f))
                    timerState.(f) = char(timerState.(f));
                end
            end
            if ~isempty(timerState.expiredColor)
                timerState.expiredColor = timerState.expiredColor(1);
            end
        end
        

        function yes = hasColorOpened(timerState, color)
            timerState = GameState.normalizeTimerState(timerState);
            yes = false;
            if nargin < 2 || isempty(color)
                return;
            end
            if color == 'w'
                yes = logical(timerState.whiteOpened);
            else
                yes = logical(timerState.blackOpened);
            end
        end

        function timerState = setColorOpened(timerState, color, opened)
            timerState = GameState.normalizeTimerState(timerState);
            if nargin < 3
                opened = true;
            end
            opened = logical(opened);
            if nargin < 2 || isempty(color)
                return;
            end
            if color == 'w'
                timerState.whiteOpened = opened;
            else
                timerState.blackOpened = opened;
            end
        end

        function secs = elapsedSeconds(startIso, endIso)
            secs = 0;
            if nargin < 1 || isempty(startIso)
                return;
            end
            if nargin < 2 || isempty(endIso)
                endIso = GameState.nowISO();
            end
            try
                secs = max(0, round((datenum(endIso, 'yyyy-mm-ddTHH:MM:SS') - ...
                    datenum(startIso, 'yyyy-mm-ddTHH:MM:SS')) * 86400));
            catch
                secs = 0;
            end
        end
        
        function timerState = applyElapsedToTimer(timerState, nowIso)
            timerState = GameState.normalizeTimerState(timerState);
            if nargin < 2 || isempty(nowIso)
                nowIso = GameState.nowISO();
            end
            if ~timerState.enabled || ~timerState.running || isempty(timerState.startedAt)
                return;
            end
            elapsed = GameState.elapsedSeconds(timerState.startedAt, nowIso);
            if timerState.activeColor == 'w'
                timerState.whiteRemainingSec = max(0, timerState.whiteRemainingSec - elapsed);
                if timerState.whiteRemainingSec <= 0
                    timerState.expiredColor = 'w';
                    timerState.running = false;
                end
            else
                timerState.blackRemainingSec = max(0, timerState.blackRemainingSec - elapsed);
                if timerState.blackRemainingSec <= 0
                    timerState.expiredColor = 'b';
                    timerState.running = false;
                end
            end
            timerState.startedAt = '';
        end
        
        function state = fromModel(model)
            state                = struct();
            state.schemaVersion  = 3;
            state.gameId         = '';
            state.hostColor      = '';
            state.createdAt      = '';
            state.updatedAt      = GameState.nowISO();
            board                = repmat('.', 8, 8);
            moved                = false(8, 8);
            for file = 1:8
                for rank = 1:8
                    square = model.chessBoardBoxes(file, rank);
                    if isempty(square.button); continue; end
                    piece = square.button.UserData;
                    if isempty(piece) || ischar(piece); continue; end
                    c = piece.id;
                    if piece.color == 'b'
                        c = lower(c);
                    end
                    board(rank, file) = c;
                    moved(rank, file) = logical(piece.used);
                end
            end
            state.board          = cellstr(board);
            state.moved          = moved;
            state.turn           = 'w';
            state.moveNumber     = 1;
            state.halfmoveClock  = 0;
            state.lastMove       = [];
            state.history        = {};
            state.status         = 'active';
            if isprop(model, 'enPassantInfo')
                state.enPassantInfo = model.enPassantInfo;
            else
                state.enPassantInfo = [];
            end
            state.timer = GameState.makeTimerState(false, 10);
        end
        
        function applyToModel(state, model, controller, gui)
            for file = 1:8
                for rank = 1:8
                    btn = model.chessBoardBoxes(file, rank).button;
                    if ~isempty(btn)
                        set(btn, 'CData', [], 'UserData', '');
                    end
                end
            end
            model.chessBoardMap = zeros(8,8);
            if isfield(state, 'enPassantInfo')
                model.enPassantInfo = state.enPassantInfo;
            else
                model.enPassantInfo = [];
            end
            
            boardChars = char(state.board);
            for row = 1:8
                for col = 1:8
                    c = boardChars(row, col);
                    if c == '.'; continue; end
                    color = 'w'; if c == lower(c); color = 'b'; end
                    upperC = upper(c);
                    file = col; rank = row;
                    piece = GameState.makePiece(upperC, model, color, [file rank]);
                    if isempty(piece); continue; end
                    piece.used = logical(state.moved(row, col));
                    imgName = sprintf('resources/%s%s.png', upperC, upper(color));
                    set(model.chessBoardBoxes(file, rank).button, ...
                        'CData',    ChessBoardGUI.createRGB(imgName), ...
                        'UserData', piece, ...
                        'Enable',   'on');
                    model.chessBoardMap(rank, file) = double(upperC);
                end
            end
            controller.setRound(state.moveNumber);
            if nargin >= 4 && ~isempty(gui)
                gui.redrawAfterStateLoad(state);
            end
        end
        
        function piece = makePiece(upperC, model, color, position)
            switch upperC
                case 'P'; piece = Pawn(model, color, position);
                case 'R'; piece = Rook(model, color, position);
                case 'N'; piece = Knight(model, color, position);
                case 'B'; piece = Bishop(model, color, position);
                case 'Q'; piece = Queen(model, color, position);
                case 'K'; piece = King(model, color, position);
                otherwise; piece = [];
            end
        end
        
        function txt = toJSON(state)
            try
                txt = jsonencode(state, 'PrettyPrint', true);
            catch
                txt = jsonencode(state);
            end
        end
        
        function state = fromJSON(txt)
            state = jsondecode(txt);
            if isfield(state, 'moved') && ~islogical(state.moved)
                state.moved = logical(state.moved);
            end
            if isfield(state, 'board')
                if isstring(state.board)
                    state.board = cellstr(state.board);
                elseif ischar(state.board)
                    state.board = cellstr(state.board);
                end
            end
            for fld = {'turn','hostColor','status','gameId','createdAt','updatedAt'}
                f = fld{1};
                if isfield(state, f) && isstring(state.(f))
                    state.(f) = char(state.(f));
                end
            end
            if isfield(state, 'turn') && ~isempty(state.turn)
                state.turn = state.turn(1);
            end
            if isfield(state, 'hostColor') && ~isempty(state.hostColor)
                state.hostColor = state.hostColor(1);
            end
            if isfield(state, 'enPassantInfo') && isstruct(state.enPassantInfo)
                epi = state.enPassantInfo;
                for fld = {'target','victim'}
                    f = fld{1};
                    if isfield(epi, f) && isnumeric(epi.(f))
                        epi.(f) = double(epi.(f)(:).');
                        if numel(epi.(f)) ~= 2
                            epi.(f) = [];
                        end
                    else
                        epi.(f) = [];
                    end
                end
                if isfield(epi, 'capturerColor')
                    if isstring(epi.capturerColor)
                        epi.capturerColor = char(epi.capturerColor);
                    end
                    if ischar(epi.capturerColor) && ~isempty(epi.capturerColor)
                        epi.capturerColor = epi.capturerColor(1);
                    else
                        epi.capturerColor = '';
                    end
                else
                    epi.capturerColor = '';
                end
                state.enPassantInfo = epi;
            elseif ~isfield(state, 'enPassantInfo')
                state.enPassantInfo = [];
            end
            if isfield(state, 'history')
                h = state.history;
                if isempty(h)
                    state.history = {};
                elseif iscell(h)
                    state.history = h(:);
                elseif isstruct(h)
                    state.history = arrayfun(@(x) x, h, 'UniformOutput', false);
                    state.history = state.history(:);
                else
                    state.history = {};
                end
            else
                state.history = {};
            end
            if isfield(state, 'timer')
                state.timer = GameState.normalizeTimerState(state.timer);
            else
                state.timer = GameState.makeTimerState(false, 10);
            end
            if ~isfield(state, 'schemaVersion')
                state.schemaVersion = 2;
            end
        end
        
        function id = newGameId()
            id = lower(dec2hex(randi([0 15], 1, 16), 1));
            id = id(:)';
        end
        
        function s = nowISO()
            s = datestr(now, 'yyyy-mm-ddTHH:MM:SS');
        end
    end
end
