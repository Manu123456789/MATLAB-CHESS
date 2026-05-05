classdef ChessBoardGUI < handle
    % ChessBoardGUI
    % -------------
    % Renders the board, handles clicks, and mediates moves. Changes vs the
    % original:
    %   - Orientation-aware board layout (white-on-bottom OR black-on-bottom)
    %   - Overlay-based legal-move highlights (dots + capture tint) that
    %     don't clobber piece images
    %   - Clicking a non-legal square deselects cleanly
    %   - Status bar at top shows whose turn, check state, last move
    %   - Manual Refresh button for networked play
    %   - Input is locked when it's not the player's turn (network mode)
    %
    % Public ctor variants:
    %   ChessBoardGUI(model, controller)                      -- local play
    %   ChessBoardGUI(model, controller, netGame, orientation)
    %       netGame     -- a NetGame handle (bootstrapped by ChessMasters)
    %       orientation -- 'w' or 'b', which side is on the bottom

    properties (GetAccess = public, SetAccess = private)
        gameController
        chessBoardModel
        netGame                  = []     % empty in local mode
        stockfishBot             = []     % non-empty in local Stockfish mode
        playerColor              = 'w'    % human color in Stockfish mode
        botThinking              = false
        botTriggerTimer          = []
        orientation              = 'w'    % 'w' or 'b'
        figureHandle
        statusText
        refreshButton
        pauseButton
        endTurnButton            = []
        undoButton               = []
        clearPremovesButton      = []
        replayButton             = []
        prevMoveButton           = []
        nextMoveButton           = []
        liveButton               = []
        historyButton            = []
        historyFigure            = []     % handle to the open history viewer, if any

        % Captured-piece graveyard ---------------------------------------
        capturedWhitePanel       = []     % black pieces captured by White
        capturedBlackPanel       = []     % white pieces captured by Black
        capturedWhiteIcons       = []
        capturedBlackIcons       = []

        % Post-game Stockfish analysis panel ----------------------------
        analysisPanel            = []
        analysisText             = []
        analysisAnalyzeButton    = []
        analysisPlayButton       = []
        analysisEngineButton     = []
        analysisStockfishBot     = []
        analysisEnginePath       = ''
        analysisBestMove         = []
        analysisBestFen          = ''
        analysisBusy             = false

        % Local-mode history cache. Networked games already persist the
        % same data in netGame.lastSeenState.history; local mode needs a
        % lightweight in-memory equivalent so the graveyard has the same
        % source-of-truth behavior.
        localMoveHistory         = {}
        localGameStatus          = 'active'

        % Rewind state: [] means live (board shows latest position).
        % An integer N means the board is rendered from history{N};
        % live gameplay is locked, poll still runs but skips re-render.
        rewindIndex              = []

        % Review mode: entered from the end-of-game dialog. Allows
        % the user to play moves from any rewound position to explore
        % alternate continuations. Variations are throwaway -- any
        % Prev/Next/Live or new rewind point discards them. Network
        % save, polling, timer, and game-end notifications are all
        % suppressed while in review mode.
        isReviewMode             = false
        % True once a move has been played from the current rewound
        % position in review mode (so we know to enforce strict
        % alternation rather than free choice). Reset on every
        % rewind navigation or Live click.
        reviewVariationActive    = false
        timerWhiteText
        timerBlackText
        moveTimerObj             = []
        pollTimerObj             = []     % network-mode auto-refresh timer
        autoNoMovePollCount      = 0      % auto-poll cycles spent waiting for opponent
        localTimerState          = []
        timerExpiredLocal        = false
        endDialogShown           = false

        % Selection state ------------------------------------------------
        selectedFile             = []     % 1..8 or []
        selectedRank             = []     % 1..8 or []
        selectedOrigBg           = []     % background color before selection
        highlightSnapshot        = {}     % cell array of snapshot structs

        % Pending-handoff state -----------------------------------------
        % When non-empty, the mover has applied their move visually but
        % has NOT yet committed (persisted / handed off turn). Contains
        % all info needed to roll the move back via undoPendingMove, or
        % to finish it via commitPendingMove.
        pendingMove              = []

        % Premove state (network mode only) -----------------------------
        % Queue of unconditional premoves. Each entry is a struct
        % with myFrom and myTo. The user enters them by clicking
        % their own piece then a destination during the opponent's
        % turn -- same selection mechanic as a normal move, but
        % routed to the queue instead of performMove. The queue is
        % capped at PREMOVE_QUEUE_MAX (see constants below).
        %
        % On opponent's next move (any move), the queue is consumed
        % head-first: each premove fires if its piece is still on
        % the source square AND the move is reachable AND wouldn't
        % expose our own king. Any failure discards the entire
        % remaining queue.
        %
        % Stored ONLY here in-process -- never written to the shared
        % JSON -- so the opponent cannot see it.
        premoveQueue             = {}

        % Cached dot image (generated once) ------------------------------
        dotCData

        % Semaphore: set during applyToModel to suppress click handling
        suppressInput            = false
    end

    properties (Constant, Access = private)
        COLOR_SELECTED      = [1 1 0.4]       % selected piece background (pale yellow)
        COLOR_CAPTURE       = [1 0.72 0.72]   % capture target background (pale red)
        COLOR_LASTMOVE      = [0.76 0.9 0.6]  % from/to flash after opponent moves
        COLOR_PENDING       = [1 0.93 0.55]   % pending-handoff move (deeper yellow)
        COLOR_PREMOVE_MINE  = [0.6 0.82 1]    % queued premove from/to (blue)
        TILE_PX          = 100
        BOARD_ORIGIN_X   = 45
        BOARD_ORIGIN_Y   = 55
        TOP_BAR_HEIGHT   = 60
        FIGURE_W         = 1490
        CAPTURE_PANEL_X  = 1245
        CAPTURE_PANEL_W  = 220
        CAPTURE_PANEL_H  = 240
        CAPTURE_PANEL_GAP = 10
        ANALYSIS_PANEL_H = 300
        CAPTURE_ICON_PX  = 30
        CAPTURE_ICON_GAP = 6
        CAPTURE_GRID_COLS = 5
        PREMOVE_QUEUE_MAX = 4                 % chess.com-style cap

        % Auto-poll (network mode): each tick is scheduled POLL_MIN_SEC
        % + rand*POLL_JITTER_SEC seconds after the previous one fires,
        % so two clients that opened the same game never fall into
        % phase-lock and hammer the share point simultaneously.
        POLL_MIN_SEC     = 1
        POLL_JITTER_SEC  = 1
        LONG_WAIT_POLL_THRESHOLD = 20
    end

    methods
        function this = ChessBoardGUI(chessBoardModel, gameController, netGame, orientation, localTimerState, stockfishBot, playerColor)
            this.gameController  = gameController;
            this.chessBoardModel = chessBoardModel;
            if nargin >= 3 && ~isempty(netGame);     this.netGame     = netGame;     end
            if nargin >= 4 && ~isempty(orientation); this.orientation = orientation; end
            if nargin >= 5 && ~isempty(localTimerState); this.localTimerState = GameState.normalizeTimerState(localTimerState); end
            if nargin >= 6 && ~isempty(stockfishBot); this.stockfishBot = stockfishBot; end
            if nargin >= 7 && ~isempty(playerColor)
                pc = char(playerColor);
                this.playerColor = pc(1);
            end
            if ~isempty(this.stockfishBot) && isprop(this.stockfishBot, 'enginePath')
                this.analysisEnginePath = this.stockfishBot.enginePath;
            end

            this.dotCData = ChessBoardGUI.makeDotImage(this.TILE_PX, 14, [0.35 0.35 0.35]);
            this.createGUI();

            % Populate pieces. In networked mode, apply loaded state;
            % in local mode, run the original starting-position placer.
            if isempty(this.netGame)
                this.gameController.placePieces();
            else
                GameState.applyToModel(this.netGame.lastSeenState, ...
                    this.chessBoardModel, this.gameController, this);
            end
            this.updateCapturedPiecesPanel();
            this.updateStatusBar();
            if isempty(this.netGame)
                this.syncClockAfterBoardLoad([], this.currentStateStruct(), true);
                this.scheduleStockfishMoveIfNeeded();
            else
                this.handleNetworkInitialOpen();
                this.startAutoPoll();
            end
        end

        function createGUI(this)
            figH = this.BOARD_ORIGIN_Y + 8*this.TILE_PX + 35 + this.TOP_BAR_HEIGHT;
            h = figure('Name','Chess Master', ...
                'Position',[300 150 this.FIGURE_W figH], ...
                'MenuBar','none','NumberTitle','off', ...
                'Color',[1 1 1],'Resize','off', ...
                'CloseRequestFcn', @(~,~) this.onFigureClosed());
            this.figureHandle = h;

            topBarY = figH - this.TOP_BAR_HEIGHT + 10;
            this.statusText = uicontrol(h, 'Style','text', 'String','', ...
                'FontSize',13, 'HorizontalAlignment','left', ...
                'BackgroundColor',[1 1 1], ...
                'Position',[this.BOARD_ORIGIN_X topBarY 590 32]);
            this.timerWhiteText = uicontrol(h, 'Style','text', 'String','White  --:--', ...
                'FontSize',12, 'HorizontalAlignment','right', ...
                'BackgroundColor',[1 1 1], 'Position',[645 topBarY 100 30]);
            this.timerBlackText = uicontrol(h, 'Style','text', 'String','Black  --:--', ...
                'FontSize',12, 'HorizontalAlignment','right', ...
                'BackgroundColor',[1 1 1], 'Position',[750 topBarY 100 30]);

            % End-Turn and Clear-Pre share slot 1; Undo occupies slot
            % 2 only with a pending move. See updateActionButtons().
            this.endTurnButton = uicontrol(h, 'Style','pushbutton', ...
                'String','End Turn', 'FontSize',11, ...
                'Position',[860 topBarY 80 30], ...
                'Visible','off', ...
                'Callback', @(~,~) this.onEndTurnClicked());
            this.undoButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Undo', 'FontSize',11, ...
                'Position',[945 topBarY 70 30], ...
                'Visible','off', ...
                'Callback', @(~,~) this.onUndoMoveClicked());
            this.clearPremovesButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Clear Pre', 'FontSize',10, ...
                'Position',[860 topBarY 80 30], ...
                'Visible','off', ...
                'Callback', @(~,~) this.onClearPremovesClicked());
            this.refreshButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Refresh', 'FontSize',11, ...
                'Position',[1020 topBarY 70 30], ...
                'Enable',   this.refreshEnableFlag(), ...
                'Callback', @(~,~) this.onRefreshClicked());
            this.pauseButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Pause', 'FontSize',11, ...
                'Position',[1095 topBarY 65 30], ...
                'Enable','off', ...
                'Callback', @(~,~) this.onPauseResumeClicked());
            this.replayButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Replay', 'FontSize',11, ...
                'Position',[1165 topBarY 70 30], ...
                'Enable','off', ...
                'Callback', @(~,~) this.onReplayLastMoveClicked());
            this.prevMoveButton = uicontrol(h, 'Style','pushbutton', ...
                'String','<', 'FontSize',12, ...
                'Position',[1240 topBarY 30 30], ...
                'Enable','off', ...
                'Callback', @(~,~) this.onPrevMoveClicked());
            this.nextMoveButton = uicontrol(h, 'Style','pushbutton', ...
                'String','>', 'FontSize',12, ...
                'Position',[1275 topBarY 30 30], ...
                'Enable','off', ...
                'Callback', @(~,~) this.onNextMoveClicked());
            this.liveButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Live', 'FontSize',11, ...
                'Position',[1310 topBarY 55 30], ...
                'Enable','off', ...
                'Callback', @(~,~) this.onLiveClicked());
            this.historyButton = uicontrol(h, 'Style','pushbutton', ...
                'String','History', 'FontSize',11, ...
                'Position',[1370 topBarY 70 30], ...
                'Enable','off', ...
                'Callback', @(~,~) this.onShowHistoryClicked());

            this.createCapturedPiecePanels();
            this.createAnalysisPanel();

            Letters = 'ABCDEFGH';
            for file = 1:8
                for rank = 1:8
                    [px, py] = this.modelToPixel(file, rank);
                    btn = uicontrol('Style','pushbutton','String','', ...
                        'Position',[px py this.TILE_PX this.TILE_PX], ...
                        'BackgroundColor',this.chessBoardModel.chessBoardBoxes(file,rank).color, ...
                        'Parent',h, 'Enable','on', ...
                        'Callback',{@this.onSquareClicked, file, rank});
                    this.chessBoardModel.chessBoardBoxes(file,rank).setButton(btn);
                end
            end

            % Edge labels (rank numbers on sides, file letters on top/bottom).
            % Orientation flips both.
            for k = 1:8
                [fileLabel, rankLabel] = this.edgeLabelsAt(k, Letters);
                labelW = 32;
                labelH = 26;
                labelFont = 14;
                fileX = this.BOARD_ORIGIN_X + this.TILE_PX*(k-1) + (this.TILE_PX-labelW)/2;
                rankY = this.BOARD_ORIGIN_Y + this.TILE_PX*(k-1) + (this.TILE_PX-labelH)/2;

                % File letters (bottom)
                uicontrol('Style','text', 'Parent',h, ...
                    'Position',[fileX, this.BOARD_ORIGIN_Y - labelH - 4, labelW, labelH], ...
                    'FontSize',labelFont,'BackgroundColor',[1 1 1], ...
                    'HorizontalAlignment','center', 'String', fileLabel);
                % File letters (top)
                uicontrol('Style','text', 'Parent',h, ...
                    'Position',[fileX, this.BOARD_ORIGIN_Y + this.TILE_PX*8 + 4, labelW, labelH], ...
                    'FontSize',labelFont,'BackgroundColor',[1 1 1], ...
                    'HorizontalAlignment','center', 'String', fileLabel);
                % Rank numbers (left)
                uicontrol('Style','text', 'Parent',h, ...
                    'Position',[this.BOARD_ORIGIN_X - labelW - 6, rankY, labelW, labelH], ...
                    'FontSize',labelFont,'BackgroundColor',[1 1 1], ...
                    'HorizontalAlignment','center', 'String', rankLabel);
                % Rank numbers (right)
                uicontrol('Style','text', 'Parent',h, ...
                    'Position',[this.BOARD_ORIGIN_X + this.TILE_PX*8 + 6, rankY, labelW, labelH], ...
                    'FontSize',labelFont,'BackgroundColor',[1 1 1], ...
                    'HorizontalAlignment','center', 'String', rankLabel);
            end
        end

        function [fileLabel, rankLabel] = edgeLabelsAt(this, k, Letters)
            if this.orientation == 'w'
                fileLabel = Letters(k);
                rankLabel = sprintf('%d', k);
            else
                fileLabel = Letters(9-k);
                rankLabel = sprintf('%d', 9-k);
            end
        end

        function [px, py] = modelToPixel(this, file, rank)
            if this.orientation == 'w'
                px = this.BOARD_ORIGIN_X + this.TILE_PX * (file - 1);
                py = this.BOARD_ORIGIN_Y + this.TILE_PX * (rank - 1);
            else
                px = this.BOARD_ORIGIN_X + this.TILE_PX * (8 - file);
                py = this.BOARD_ORIGIN_Y + this.TILE_PX * (8 - rank);
            end
        end

        % ---------------------------------------------------------------
        % Click handling
        % ---------------------------------------------------------------
        function onSquareClicked(this, btn, ~, file, rank)
            if this.suppressInput; return; end
            if ~this.isReviewMode
                if this.isTerminalStatus(this.currentGameStatus()); return; end
                if ~strcmp(this.gameController.gameStatus(), 'active'); return; end
                if this.isClockExpired(); return; end
                if this.isGamePaused(); return; end
                % Rewind locks all board input. Clicking Live returns
                % to the present position before you can move.
                if this.isRewound(); return; end
            end
            % Review mode is otherwise click-through: a rewound
            % position is the WHOLE POINT of clicking pieces, so we
            % don't bail on isRewound here.

            % Pending-handoff: the mover has already played their move
            % locally and must either commit (End Turn) or revert (Undo)
            % via the dedicated buttons. Board clicks are inert.
            if ~isempty(this.pendingMove)
                return;
            end

            % Network mode + opponent's turn: route clicks to the
            % premove queue rather than performMove. Same selection
            % UX (yellow tint on source, second click commits the
            % action), different terminal behavior.
            if ~this.isReviewMode && ~isempty(this.netGame) && ~this.netGame.isMyTurn()
                this.handlePremoveSelectionClick(file, rank);
                return;
            end

            % Stockfish mode is local, but only the human's color is
            % click-playable. The engine moves automatically on its turn.
            if ~this.isReviewMode && this.isStockfishGame()
                % Defensive recovery: if the engine lock was left set even
                % though control has returned to the human, clear it so the
                % board cannot remain click-locked after a Stockfish move.
                if this.botThinking && isempty(this.pendingMove) ...
                        && this.gameController.whoPlays() == this.playerColor
                    this.botThinking = false;
                    this.updateStatusBar();
                    this.updateActionButtons();
                end
                if this.botThinking || this.gameController.whoPlays() ~= this.playerColor
                    return;
                end
            end

            piece    = btn.UserData;
            hasPiece = ~isempty(piece) && ~ischar(piece);
            % In review mode, the FIRST move from a rewound (or
            % current) position can be either side. Once a variation
            % move has landed, we fall through to whoPlays() which
            % strictly alternates from there.
            if this.isReviewMode && ~this.reviewVariationActive
                whoPlays = [];   % sentinel: any side is acceptable
            else
                whoPlays = this.gameController.whoPlays();
            end

            if isempty(this.selectedFile)
                if hasPiece && (isempty(whoPlays) || piece.color == whoPlays)
                    this.selectSquare(file, rank);
                end
                return;
            end

            if file == this.selectedFile && rank == this.selectedRank
                this.clearSelection();
                return;
            end
            if hasPiece && (isempty(whoPlays) || piece.color == whoPlays)
                this.clearSelection();
                this.selectSquare(file, rank);
                return;
            end

            srcBtn   = this.chessBoardModel.chessBoardBoxes(this.selectedFile, this.selectedRank).button;
            srcPiece = srcBtn.UserData;
            if isempty(srcPiece); this.clearSelection(); return; end
            validMoves = srcPiece.ValidMoves();
            isLegal = ~isempty(validMoves) && ...
                any(validMoves(:,1)==file & validMoves(:,2)==rank);
            if ~isLegal
                this.clearSelection();
                return;
            end

            this.performMove(this.selectedFile, this.selectedRank, file, rank);
        end

        function selectSquare(this, file, rank, withOverlays)
            if nargin < 4; withOverlays = true; end
            btn = this.chessBoardModel.chessBoardBoxes(file, rank).button;
            this.selectedFile   = file;
            this.selectedRank   = rank;
            this.selectedOrigBg = get(btn, 'BackgroundColor');
            set(btn, 'BackgroundColor', this.COLOR_SELECTED);
            if withOverlays
                this.showLegalMoves(btn.UserData);
            end
        end

        function clearSelection(this)
            if isempty(this.selectedFile); return; end
            btn = this.chessBoardModel.chessBoardBoxes(this.selectedFile, this.selectedRank).button;
            if ishandle(btn)
                set(btn, 'BackgroundColor', this.selectedOrigBg);
            end
            this.clearHighlights();
            this.selectedFile   = [];
            this.selectedRank   = [];
            this.selectedOrigBg = [];
        end

        function showLegalMoves(this, piece)
            if isempty(piece) || ischar(piece); return; end
            paths = piece.ValidMoves();
            this.highlightSnapshot = {};
            for k = 1:size(paths,1)
                f = paths(k,1); r = paths(k,2);
                sq  = this.chessBoardModel.chessBoardBoxes(f, r);
                btn = sq.button;
                target    = btn.UserData;
                isCapture = ~isempty(target) && ~ischar(target);
                snap = struct('file',f, 'rank',r, ...
                              'bg',   get(btn,'BackgroundColor'), ...
                              'cdata',get(btn,'CData'));
                this.highlightSnapshot{end+1} = snap; %#ok<AGROW>
                if isCapture
                    set(btn, 'BackgroundColor', this.COLOR_CAPTURE);
                else
                    set(btn, 'CData', this.dotCData);
                end
            end
        end

        function clearHighlights(this)
            for k = 1:numel(this.highlightSnapshot)
                s   = this.highlightSnapshot{k};
                btn = this.chessBoardModel.chessBoardBoxes(s.file, s.rank).button;
                if ishandle(btn)
                    set(btn, 'BackgroundColor', s.bg, 'CData', s.cdata);
                end
            end
            this.highlightSnapshot = {};
        end

        % ---------------------------------------------------------------
        % Move execution
        % ---------------------------------------------------------------
        % Applies the move visually (piece moves, captures removed,
        % castle rook moved, en passant capture applied, promotion
        % resolved). The round, timer handoff, and network save are
        % DEFERRED until the player clicks End Turn; see
        % commitPendingMove. Undo is supported via undoPendingMove.
        %
        % Exception: promotion moves auto-commit -- reversing a
        % promotion requires reconstructing the Pawn, and the player
        % has already made a discrete choice in the promotion dialog,
        % so it is treated as a committed action.
        function performMove(this, srcFile, srcRank, dstFile, dstRank, promotionChoice)
            if nargin < 6; promotionChoice = ''; end
            srcBtn   = this.chessBoardModel.chessBoardBoxes(srcFile, srcRank).button;
            dstBtn   = this.chessBoardModel.chessBoardBoxes(dstFile, dstRank).button;
            srcPiece = srcBtn.UserData;

            srcPictureBefore = srcBtn.CData;
            dstPictureBefore = dstBtn.CData;
            dstPieceBefore   = dstBtn.UserData;
            srcPieceUsedBefore = srcPiece.used;
            prevEnPassantInfo = this.chessBoardModel.enPassantInfo;
            prevStateSnapshot = this.currentStateStruct();
            if isfield(prevStateSnapshot, 'timer')
                prevTimerState = prevStateSnapshot.timer;
            else
                prevTimerState = GameState.makeTimerState(false, 10);
            end

            this.clearSelection();

            castleInfo = this.computeCastleInfo(srcPiece, dstFile, dstRank);
            enPassantInfo = this.computeEnPassantCaptureInfo(srcPiece, dstFile, dstRank);
            wasCapture = (~isempty(dstPieceBefore) && ~ischar(dstPieceBefore)) || enPassantInfo.isEnPassant;
            if enPassantInfo.isEnPassant
                capturedPieceCode = this.pieceObjToBoardCode(enPassantInfo.capturedPiece);
            else
                capturedPieceCode = this.pieceObjToBoardCode(dstPieceBefore);
            end

            movedPiece = srcPiece.movePiece([dstFile dstRank]);
            set(dstBtn, 'CData', srcPictureBefore, 'UserData', movedPiece);
            set(srcBtn, 'CData', [], 'UserData', '');
            if enPassantInfo.isEnPassant
                this.applyEnPassantCapture(enPassantInfo);
            end
            if castleInfo.isCastle
                this.applyCastleRookMove(castleInfo);
            end

            isPromotion = false;
            if movedPiece.id == 'P' && this.gameController.checkPromotion(movedPiece)
                if isempty(promotionChoice)
                    this.promote(movedPiece);
                else
                    this.promoteToPiece(movedPiece, promotionChoice);
                end
                isPromotion = true;
            end

            % Would this move leave our king in check? Roll back if so.
            if movedPiece.id ~= 'K' && ~this.gameController.checkNoCoverCheck(movedPiece.color)
                this.rollbackMove(srcFile, srcRank, dstFile, dstRank, ...
                    movedPiece, dstPieceBefore, srcPictureBefore, dstPictureBefore, castleInfo, enPassantInfo, prevEnPassantInfo, srcPieceUsedBefore);
                this.notifyNoCoverCheck();
                return;
            end

            this.chessBoardModel.enPassantInfo = this.computeNextEnPassantInfo(srcPiece, srcFile, srcRank, dstFile, dstRank);

            % Stash enough state to either commit or roll back later.
            % Built field-by-field because struct(...,'x',[]) returns
            % a 0x0 struct array, and several of these fields can be [].
            pending = struct();
            pending.srcFile            = srcFile;
            pending.srcRank            = srcRank;
            pending.dstFile            = dstFile;
            pending.dstRank            = dstRank;
            pending.prevMoveNumber     = this.gameController.round;
            pending.moverColor         = srcPiece.color;
            pending.moverPieceIdOriginal = srcPiece.id;   % 'P' iff this was a pawn pre-promotion
            pending.srcPictureBefore   = srcPictureBefore;
            pending.dstPictureBefore   = dstPictureBefore;
            pending.dstPieceBefore     = dstPieceBefore;
            pending.srcPieceUsedBefore = srcPieceUsedBefore;
            pending.prevEnPassantInfo  = prevEnPassantInfo;
            pending.prevTimerState     = prevTimerState;
            pending.castleInfo         = castleInfo;
            pending.enPassantInfo      = enPassantInfo;
            pending.wasCapture         = wasCapture;
            pending.capturedPieceCode  = capturedPieceCode;
            pending.isPromotion        = isPromotion;
            this.pendingMove           = pending;

            this.paintPendingMoveHighlight();

            % Moves commit immediately -- no End Turn / Undo step.
            % The pendingMove struct above is still populated because
            % commitPendingMove reads from it; it's cleared inside
            % commitPendingMove on success.
            this.commitPendingMove();
        end

        % Commits whatever is currently in this.pendingMove: toggles
        % the clock, advances the round, persists to disk (network
        % mode), triggers any end-game notification, and clears the
        % pending state. Called from onEndTurnClicked, from
        % performMove for promotion moves, and from tryFirePremove
        % when a queued premove auto-fires.
        function commitPendingMove(this)
            if isempty(this.pendingMove); return; end
            p = this.pendingMove;

            this.clearPendingMoveHighlight();

            if this.isReviewMode
                % Review mode: visual move only. Set round so
                % whoPlays() returns the OPPONENT of whoever just
                % moved (enforces alternation from here on). We can't
                % just playRound() because the user's first variation
                % move may have been made by either side -- if they
                % chose the side OPPOSITE to whoPlays() at the time,
                % a naive increment would yield the wrong parity.
                % Instead: round odd = white to move, round even =
                % black to move; pick the smallest non-negative round
                % value that gives the right parity, while preserving
                % live the move number for display purposes via the
                % status bar's read of state.history length.
                if p.moverColor == 'w'
                    % White moved -> black to move next -> round even
                    if mod(this.gameController.round, 2) == 0
                        this.gameController.setRound(this.gameController.round + 2);
                    else
                        this.gameController.setRound(this.gameController.round + 1);
                    end
                else
                    % Black moved -> white to move next -> round odd
                    if mod(this.gameController.round, 2) == 1
                        this.gameController.setRound(this.gameController.round + 2);
                    else
                        this.gameController.setRound(this.gameController.round + 1);
                    end
                end
                this.reviewVariationActive = true;
                this.pendingMove = [];
                this.clearAnalysisBestMove({'Variation changed.', ...
                    'Click Analyze Position for this new board.'});
                this.updateStatusBar();
                this.updateActionButtons();
                return;
            end

            nextTimerState = this.timerStateAfterCompletedMove(p.prevTimerState, p.moverColor);
            this.stopMoveTimer();
            this.applyTimerStateToCurrentContext(nextTimerState);
            this.gameController.playRound();

            dstBtn    = this.chessBoardModel.chessBoardBoxes(p.dstFile, p.dstRank).button;
            finalPiece = dstBtn.UserData;  % may be a promoted piece
            opponentColor = this.oppositeColor(p.moverColor);

            % buildStateAfterMove needs the ORIGINAL mover piece id
            % (e.g. 'P' for a promotion move) to set halfmoveClock=0
            % for pawn moves and to set lastMove.promotion correctly
            % by comparing original id vs final id on the board. A
            % minimal struct proxy is sufficient for its uses.
            moverProxy = struct('id', p.moverPieceIdOriginal, 'color', p.moverColor);

            checkState = this.statusAfterMoveForOpponent(opponentColor);

            if ~isempty(this.netGame)
                state = this.buildStateAfterMove(p.srcFile, p.srcRank, p.dstFile, p.dstRank, ...
                    moverProxy, p.wasCapture, checkState, p.castleInfo, p.enPassantInfo, ...
                    nextTimerState, p.capturedPieceCode);
                if ~strcmp(state.status, 'checkmate') && ~strcmp(state.status, 'stalemate') ...
                        && this.isThreefoldRepetition(state)
                    state = this.markStateAsDraw(state, 'draw_repetition');
                    checkState = state.status;
                end
                try
                    this.netGame.save(state);
                catch err
                    % Roll back: restore the visual move AND the timer/round state.
                    this.rollbackMove(p.srcFile, p.srcRank, p.dstFile, p.dstRank, ...
                        finalPiece, p.dstPieceBefore, p.srcPictureBefore, p.dstPictureBefore, ...
                        p.castleInfo, p.enPassantInfo, p.prevEnPassantInfo, p.srcPieceUsedBefore);
                    this.applyTimerStateToCurrentContext(p.prevTimerState);
                    this.resumeTimerIfNeeded();
                    this.gameController.setRound(this.gameController.round - 1);
                    this.pendingMove = [];
                    errordlg(err.message, 'Network write failed', 'modal');
                    this.updateStatusBar();
                    this.updateActionButtons();
                    return;
                end
            else
                this.appendLocalHistoryMove(p, finalPiece, checkState);
                if ~strcmp(checkState, 'checkmate') && ~strcmp(checkState, 'stalemate') ...
                        && this.isThreefoldRepetition(this.currentLocalFullState())
                    checkState = 'draw_repetition';
                    this.markLastLocalMoveAsDraw(checkState);
                end
                if isempty(checkState)
                    this.localGameStatus = 'active';
                else
                    this.localGameStatus = checkState;
                end
            end

            this.pendingMove = [];
            this.updateCapturedPiecesPanel();

            if strcmp(checkState, 'checkmate')
                this.notifyEnd();
            elseif this.isDrawStatus(checkState)
                this.notifyDraw(checkState);
            end
            if isempty(this.netGame) && ~this.isTerminalStatus(this.localGameStatus)
                this.startTimerForColorIfEnabled(this.gameController.whoPlays(), false);
            end
            this.updateStatusBar();
            this.updateActionButtons();
            this.scheduleStockfishMoveIfNeeded();
        end

        % Undoes this.pendingMove, restoring the board exactly as it
        % was before the move was selected. Does not touch round,
        % timer, or anything networked (none of that changed yet,
        % because commitPendingMove is where those happen).
        function undoPendingMove(this)
            if isempty(this.pendingMove); return; end
            p = this.pendingMove;

            this.clearPendingMoveHighlight();

            dstBtn = this.chessBoardModel.chessBoardBoxes(p.dstFile, p.dstRank).button;
            movedPiece = dstBtn.UserData;
            this.rollbackMove(p.srcFile, p.srcRank, p.dstFile, p.dstRank, ...
                movedPiece, p.dstPieceBefore, p.srcPictureBefore, p.dstPictureBefore, ...
                p.castleInfo, p.enPassantInfo, p.prevEnPassantInfo, p.srcPieceUsedBefore);

            this.pendingMove = [];
            this.updateCapturedPiecesPanel();
            this.updateStatusBar();
            this.updateActionButtons();
        end

        function onEndTurnClicked(this)
            if isempty(this.pendingMove); return; end
            this.commitPendingMove();
        end

        function onUndoMoveClicked(this)
            if isempty(this.pendingMove); return; end
            this.undoPendingMove();
        end

        function rollbackMove(this, srcFile, srcRank, dstFile, dstRank, ...
                movedPiece, dstPieceBefore, srcPictureBefore, dstPictureBefore, castleInfo, enPassantInfo, prevEnPassantInfo, srcPieceUsedBefore)
            if nargin < 10 || isempty(castleInfo)
                castleInfo = struct('isCastle', false);
            end
            if nargin < 11 || isempty(enPassantInfo)
                enPassantInfo = struct('isEnPassant', false);
            end
            if nargin < 12
                prevEnPassantInfo = [];
            end
            if nargin < 13
                srcPieceUsedBefore = false;
            end
            movedPiece = movedPiece.movePiece([srcFile srcRank]);
            dstBtn = this.chessBoardModel.chessBoardBoxes(dstFile, dstRank).button;
            srcBtn = this.chessBoardModel.chessBoardBoxes(srcFile, srcRank).button;
            if ~isempty(dstPieceBefore) && ~ischar(dstPieceBefore)
                set(dstBtn, 'CData', dstPictureBefore, 'UserData', dstPieceBefore);
                this.chessBoardModel.chessBoardMap(dstRank, dstFile) = dstPieceBefore.id;
            else
                set(dstBtn, 'CData', [], 'UserData', '');
                this.chessBoardModel.chessBoardMap(dstRank, dstFile) = 0;
                movedPiece.used = srcPieceUsedBefore;
            end
            set(srcBtn, 'CData', srcPictureBefore, 'UserData', movedPiece);
            if enPassantInfo.isEnPassant
                this.rollbackEnPassantCapture(enPassantInfo);
            end
            if castleInfo.isCastle
                this.rollbackCastleRookMove(castleInfo);
            end
            movedPiece.used = srcPieceUsedBefore;
            this.chessBoardModel.enPassantInfo = prevEnPassantInfo;
        end

        function state = buildStateAfterMove(this, srcFile, srcRank, dstFile, dstRank, ...
                movedPiece, wasCapture, checkState, castleInfo, enPassantInfo, nextTimerState, capturedPieceCode)
            state              = GameState.fromModel(this.chessBoardModel);
            prev               = this.netGame.lastSeenState;
            state.gameId       = prev.gameId;
            state.hostColor    = prev.hostColor;
            state.createdAt    = prev.createdAt;
            state.moveNumber   = prev.moveNumber + 1;
            if mod(state.moveNumber-1, 2) == 0
                state.turn = 'w';
            else
                state.turn = 'b';
            end
            state.halfmoveClock = prev.halfmoveClock + 1;
            if movedPiece.id == 'P' || wasCapture
                state.halfmoveClock = 0;
            end
            % Read the final piece from the destination square -- if this
            % move was a pawn promotion, the promote() popup has already
            % replaced the Pawn object with Queen/Rook/Bishop/Knight, and
            % we want the promoted id in lastMove.piece, not 'P'.
            finalPiece   = this.chessBoardModel.chessBoardBoxes(dstFile, dstRank).button.UserData;
            finalPieceId = movedPiece.id;
            finalColor   = movedPiece.color;
            wasPromotion = false;
            if ~isempty(finalPiece) && ~ischar(finalPiece)
                finalPieceId = finalPiece.id;
                finalColor   = finalPiece.color;
                wasPromotion = (movedPiece.id == 'P') && (finalPieceId ~= 'P');
            end
            if nargin < 9 || isempty(castleInfo)
                castleInfo = struct('isCastle', false, 'side', '');
            end
            if nargin < 10 || isempty(enPassantInfo)
                enPassantInfo = struct('isEnPassant', false);
            end
            if nargin < 12 || isempty(capturedPieceCode)
                capturedPieceCode = '';
            end
            state.enPassantInfo = this.chessBoardModel.enPassantInfo;
            state.lastMove = struct( ...
                'moveNumber', prev.moveNumber, ...
                'from',      [srcRank srcFile], ...
                'to',        [dstRank dstFile], ...
                'piece',     finalPieceId, ...
                'color',     finalColor, ...
                'capture',   wasCapture, ...
                'capturedPiece', capturedPieceCode, ...
                'promotion', wasPromotion, ...
                'castle',    castleInfo.isCastle, ...
                'castleSide', castleInfo.side, ...
                'enPassant', enPassantInfo.isEnPassant, ...
                'check',     strcmp(checkState, 'check'), ...
                'checkmate', strcmp(checkState, 'checkmate'), ...
                'stalemate', strcmp(checkState, 'stalemate'), ...
                'draw',      this.isDrawStatus(checkState), ...
                'drawReason', this.drawReasonForStatus(checkState), ...
                'drawRepetition', strcmp(checkState, 'draw_repetition'), ...
                'at',        GameState.nowISO(), ...
                'boardAfter', {state.board}, ...
                'movedAfter', state.moved, ...
                'turnAfter', state.turn);
            state.lastMove.enPassantInfoAfter = state.enPassantInfo;
            state.history = [prev.history; {state.lastMove}];
            if isempty(checkState)
                state.status = 'active';
            else
                state.status = checkState;
            end
            if nargin >= 10 && ~isempty(nextTimerState)
                state.timer = GameState.normalizeTimerState(nextTimerState);
            else
                state.timer = GameState.makeTimerState(false, 10);
            end
        end

        function info = computeCastleInfo(~, piece, dstFile, dstRank)
            info = struct('isCastle', false, 'side', '', ...
                'rookPiece', [], 'rookSrcFile', [], 'rookSrcRank', [], ...
                'rookDstFile', [], 'rookDstRank', [], ...
                'rookSrcPicture', [], 'rookDstPicture', []);
            if isempty(piece) || ischar(piece) || piece.id ~= 'K'
                return;
            end
            if dstRank ~= piece.position(2) || abs(dstFile - piece.position(1)) ~= 2
                return;
            end
            info.isCastle = true;
            if dstFile > piece.position(1)
                info.side = 'king';
                info.rookSrcFile = 8;
                info.rookDstFile = 6;
            else
                info.side = 'queen';
                info.rookSrcFile = 1;
                info.rookDstFile = 4;
            end
            info.rookSrcRank = piece.position(2);
            info.rookDstRank = piece.position(2);
        end

        function applyCastleRookMove(this, castleInfo)
            if ~castleInfo.isCastle
                return;
            end
            rookSrcBtn = this.chessBoardModel.chessBoardBoxes(castleInfo.rookSrcFile, castleInfo.rookSrcRank).button;
            rookDstBtn = this.chessBoardModel.chessBoardBoxes(castleInfo.rookDstFile, castleInfo.rookDstRank).button;
            rookPiece = rookSrcBtn.UserData;
            castleInfo.rookPiece = rookPiece; %#ok<NASGU>
            rookPicture = rookSrcBtn.CData;
            movedRook = rookPiece.movePiece([castleInfo.rookDstFile castleInfo.rookDstRank]);
            set(rookDstBtn, 'CData', rookPicture, 'UserData', movedRook);
            set(rookSrcBtn, 'CData', [], 'UserData', '');
        end

        function rollbackCastleRookMove(this, castleInfo)
            if ~castleInfo.isCastle
                return;
            end
            rookDstBtn = this.chessBoardModel.chessBoardBoxes(castleInfo.rookDstFile, castleInfo.rookDstRank).button;
            rookSrcBtn = this.chessBoardModel.chessBoardBoxes(castleInfo.rookSrcFile, castleInfo.rookSrcRank).button;
            rookPiece = rookDstBtn.UserData;
            if isempty(rookPiece) || ischar(rookPiece)
                return;
            end
            rookPicture = rookDstBtn.CData;
            rookPiece.movePiece([castleInfo.rookSrcFile castleInfo.rookSrcRank]);
            rookPiece.used = false;
            set(rookSrcBtn, 'CData', rookPicture, 'UserData', rookPiece);
            set(rookDstBtn, 'CData', [], 'UserData', '');
        end


        function info = computeEnPassantCaptureInfo(this, piece, dstFile, dstRank)
            info = struct('isEnPassant', false, 'capturedPiece', [], ...
                'capturedFile', [], 'capturedRank', [], ...
                'capturedPicture', []);
            if isempty(piece) || ischar(piece) || piece.id ~= 'P'
                return;
            end
            dstOccupant = this.chessBoardModel.chessBoardBoxes(dstFile, dstRank).button.UserData;
            if ~isempty(dstOccupant) && ~ischar(dstOccupant)
                return;
            end
            epi = this.chessBoardModel.enPassantInfo;
            if isempty(epi) || ~isstruct(epi) || ~isfield(epi, 'target') || ~isfield(epi, 'victim') || ~isfield(epi, 'capturerColor')
                return;
            end

            target = epi.target;
            victim = epi.victim;
            capturerColor = epi.capturerColor;

            if isstring(capturerColor)
                capturerColor = char(capturerColor);
            end
            if isempty(capturerColor) || ~ischar(capturerColor)
                return;
            end
            capturerColor = capturerColor(1);

            if ~isnumeric(target) || ~isnumeric(victim)
                return;
            end
            target = double(target(:).');
            victim = double(victim(:).');
            if numel(target) ~= 2 || numel(victim) ~= 2
                return;
            end

            if ~isequal(target, [dstFile dstRank]) || piece.color ~= capturerColor
                return;
            end
            info.isEnPassant = true;
            info.capturedFile = victim(1);
            info.capturedRank = victim(2);
            capturedBtn = this.chessBoardModel.chessBoardBoxes(info.capturedFile, info.capturedRank).button;
            info.capturedPiece = capturedBtn.UserData;
            info.capturedPicture = capturedBtn.CData;
        end

        function applyEnPassantCapture(this, info)
            if ~info.isEnPassant
                return;
            end
            capturedBtn = this.chessBoardModel.chessBoardBoxes(info.capturedFile, info.capturedRank).button;
            set(capturedBtn, 'CData', [], 'UserData', '');
            this.chessBoardModel.chessBoardMap(info.capturedRank, info.capturedFile) = 0;
        end

        function rollbackEnPassantCapture(this, info)
            if ~info.isEnPassant
                return;
            end
            capturedBtn = this.chessBoardModel.chessBoardBoxes(info.capturedFile, info.capturedRank).button;
            set(capturedBtn, 'CData', info.capturedPicture, ...
                'UserData', info.capturedPiece);
            this.chessBoardModel.chessBoardMap(info.capturedRank, info.capturedFile) = info.capturedPiece.id;
        end

        function info = computeNextEnPassantInfo(~, piece, srcFile, srcRank, dstFile, dstRank)
            info = [];
            if isempty(piece) || ischar(piece) || piece.id ~= 'P'
                return;
            end
            if abs(dstRank - srcRank) ~= 2
                return;
            end
            capturerColor = 'w';
            step = 1;
            if piece.color == 'w'
                capturerColor = 'b';
            else
                step = -1;
            end
            info = struct( ...
                'target', [dstFile dstRank - step], ...
                'victim', [dstFile dstRank], ...
                'capturerColor', capturerColor, ...
                'movedPawnColor', piece.color);
        end

        % ---------------------------------------------------------------
        % Premoves (network mode only)
        % ---------------------------------------------------------------
        % Premoves are stored client-side only, in this.premoveQueue.
        % They are NEVER serialized to the shared GameState, so the
        % opponent cannot observe them -- they read a plain board
        % snapshot from disk, nothing about what we might play.
        %
        % Each entry is a struct {myFrom, myTo}. The user enters them
        % during the opponent's turn by clicking source and dest --
        % same selection mechanic as a normal move, but routed here.
        %
        % On the opponent's next move, tryFirePremove walks the queue
        % from head to tail. Each premove fires unconditionally if
        % its piece is still on the source square AND the move is
        % reachable AND wouldn't expose our king. Any failure
        % discards the entire remaining queue (a chess.com-style
        % multi-step plan typically depends on every step landing).

        function onClearPremovesClicked(this)
            if isempty(this.premoveQueue); return; end
            this.clearPremoveQueueHighlights();
            this.premoveQueue = {};
            this.clearSelection();
            this.updateStatusBar();
            this.updateActionButtons();
        end

        % Click handler for the "opponent's turn" branch of
        % onSquareClicked. Same shape as the live-move selection
        % flow: pick source, then click destination, but the result
        % is queued instead of executed.
        function handlePremoveSelectionClick(this, file, rank)
            % Note: the queue cap check happens AFTER source-click
            % validation but BEFORE accepting a destination, so a
            % cap-rejected click with no source selected feels like
            % nothing happened (consistent with other ignored clicks).
            btn = this.chessBoardModel.chessBoardBoxes(file, rank).button;
            piece = btn.UserData;
            hasPiece = ~isempty(piece) && ~ischar(piece);
            myColor  = this.netGame.myColor;

            % Source-click phase: empty selection, must click one of
            % MY pieces -- evaluated against the HYPOTHETICAL board
            % after all queued premoves have fired (so a chained
            % premove from the destination of a prior premove works).
            if isempty(this.selectedFile)
                if numel(this.premoveQueue) >= this.PREMOVE_QUEUE_MAX
                    return;   % queue full; status bar will show why
                end
                hypoMap = this.hypotheticalBoardMap();
                if ~this.squareHoldsMyPiece(hypoMap, file, rank, myColor)
                    return;
                end
                % No legal-move dots: legality at fire time depends
                % on opponent's response, which we can't know.
                this.selectSquare(file, rank, false);
                return;
            end

            % Destination phase. Re-clicking the source clears it.
            if file == this.selectedFile && rank == this.selectedRank
                this.clearSelection();
                return;
            end
            % Clicking another of my pieces (in the hypothetical
            % board) re-anchors the selection. Same UX as live.
            hypoMap = this.hypotheticalBoardMap();
            if this.squareHoldsMyPiece(hypoMap, file, rank, myColor)
                this.clearSelection();
                this.selectSquare(file, rank, false);
                return;
            end

            % Otherwise the click is the destination. We don't try
            % to validate reachability here -- after queued premoves
            % the actual piece on the source may be different than
            % what's currently visible, and the opponent's response
            % can change which paths are blocked. Legality is
            % checked once the queue fires.
            pm = struct('myFrom', [this.selectedFile this.selectedRank], ...
                        'myTo',   [file rank]);
            this.clearSelection();
            this.premoveQueue{end+1} = pm; %#ok<AGROW>
            this.paintPremoveHighlights(pm);
            this.updateStatusBar();
            this.updateActionButtons();
        end

        % Returns an 8x8 cell array of color chars ('w'/'b'/'') for
        % the board AS IT WOULD BE after every currently-queued
        % premove has fired in order. Used to gate source-square
        % selection during multi-step entry, so a chained premove
        % from a piece's PLANNED destination is allowed even though
        % the visible board still shows it on its current square.
        %
        % Reads the current visible board's piece-color from each
        % square's button.UserData, then walks the queue and shuffles
        % chars per premove from->to. No legality check -- queue
        % entry already validated source presence at insert time.
        function map = hypotheticalBoardMap(this)
            map = repmat({''}, 8, 8);   % rows = rank, cols = file
            for f = 1:8
                for r = 1:8
                    btn = this.chessBoardModel.chessBoardBoxes(f, r).button;
                    p = btn.UserData;
                    if ~isempty(p) && ~ischar(p)
                        map{r, f} = p.color;
                    end
                end
            end
            for k = 1:numel(this.premoveQueue)
                pm = this.premoveQueue{k};
                fF = pm.myFrom(1); fR = pm.myFrom(2);
                tF = pm.myTo(1);   tR = pm.myTo(2);
                if fR < 1 || fR > 8 || fF < 1 || fF > 8 || ...
                   tR < 1 || tR > 8 || tF < 1 || tF > 8
                    continue;   % defensive
                end
                map{tR, tF} = map{fR, fF};
                map{fR, fF} = '';
            end
        end

        % Tells whether the (file,rank) square in the given
        % hypothetical-board map (cell array of color chars) holds
        % one of our pieces.
        function tf = squareHoldsMyPiece(~, map, file, rank, myColor)
            tf = false;
            if rank < 1 || rank > 8 || file < 1 || file > 8; return; end
            ch = map{rank, file};
            if isempty(ch); return; end
            tf = (ch == myColor);
        end

        function paintPremoveHighlights(this, pm)
            this.tintSquare(pm.myFrom(1),  pm.myFrom(2),  this.COLOR_PREMOVE_MINE);
            this.tintSquare(pm.myTo(1),    pm.myTo(2),    this.COLOR_PREMOVE_MINE);
        end

        function paintAllPremoveHighlights(this)
            for k = 1:numel(this.premoveQueue)
                this.paintPremoveHighlights(this.premoveQueue{k});
            end
        end

        function clearPremoveQueueHighlights(this)
            % Reset each square touched by a premove back to its
            % natural board color. We don't snapshot/restore because
            % the only other persistent tints are selection and the
            % pending-move highlight, both of which we guarantee are
            % not active at the moments we call this.
            for k = 1:numel(this.premoveQueue)
                pm = this.premoveQueue{k};
                pts = [pm.myFrom; pm.myTo];
                for i = 1:size(pts,1)
                    this.resetSquareBgToNatural(pts(i,1), pts(i,2));
                end
            end
        end

        function tintSquare(this, file, rank, color)
            btn = this.chessBoardModel.chessBoardBoxes(file, rank).button;
            if ishandle(btn)
                set(btn, 'BackgroundColor', color);
            end
        end

        function resetSquareBgToNatural(this, file, rank)
            sq  = this.chessBoardModel.chessBoardBoxes(file, rank);
            btn = sq.button;
            if ishandle(btn)
                set(btn, 'BackgroundColor', sq.color);
            end
        end

        function paintPendingMoveHighlight(this)
            if isempty(this.pendingMove); return; end
            p = this.pendingMove;
            this.tintSquare(p.srcFile, p.srcRank, this.COLOR_PENDING);
            this.tintSquare(p.dstFile, p.dstRank, this.COLOR_PENDING);
        end

        function clearPendingMoveHighlight(this)
            if isempty(this.pendingMove); return; end
            p = this.pendingMove;
            this.resetSquareBgToNatural(p.srcFile, p.srcRank);
            this.resetSquareBgToNatural(p.dstFile, p.dstRank);
        end

        % Called after a refresh brings in an opponent move. Walks
        % the queue from head to tail, firing each premove if it's
        % legal given the now-current board. Any failure (piece
        % gone, path blocked, would-expose-king) discards the rest
        % of the queue.
        %
        % Returns true iff at least one premove fired and committed.
        function fired = tryFirePremove(this, newState)
            fired = false;
            if isempty(this.netGame);            return; end
            if this.isReviewMode;                return; end
            if isempty(this.premoveQueue);       return; end
            if ~this.netGame.isMyTurn();         return; end  % only on our turn
            if ~strcmp(newState.status, 'active') && ~strcmp(newState.status, 'check')
                % Game is over (checkmate/timeout/paused etc.) -- don't fire.
                this.clearPremoveQueueHighlights();
                this.premoveQueue = {};
                return;
            end

            % Multi-step loop: each iteration either fires a premove
            % (advancing to the next, since alternation is required
            % between us and the opponent in real play) or discards
            % the rest. We can fire AT MOST one premove per refresh
            % because the opponent has to play between our moves --
            % so this loop in practice runs once. Kept as a loop in
            % case future changes ever allow chained no-opponent
            % consumption.
            while ~isempty(this.premoveQueue)
                if ~this.netGame.isMyTurn()
                    break;   % we just fired and it's opponent's turn now
                end
                head = this.premoveQueue{1};

                % Source square must still hold one of our pieces.
                srcBtn = this.chessBoardModel.chessBoardBoxes(head.myFrom(1), head.myFrom(2)).button;
                mine = srcBtn.UserData;
                if isempty(mine) || ischar(mine) || mine.color ~= this.netGame.myColor
                    this.clearPremoveQueueHighlights();
                    this.premoveQueue = {};
                    break;
                end
                % Move must be reachable.
                moves = mine.ValidMoves();
                isLegalShape = ~isempty(moves) && any(moves(:,1)==head.myTo(1) & moves(:,2)==head.myTo(2));
                if ~isLegalShape
                    this.clearPremoveQueueHighlights();
                    this.premoveQueue = {};
                    break;
                end
                % Move must not expose our own king to check.
                if ~this.gameController.isLegalMoveForColor(mine, head.myTo)
                    this.clearPremoveQueueHighlights();
                    this.premoveQueue = {};
                    break;
                end

                % Consume the head premove. Clear ALL queue tints
                % first because the board is about to change and we
                % don't want stale tints stranded on shifted pieces.
                this.clearPremoveQueueHighlights();
                this.premoveQueue(1) = [];

                % Premove-fired moves auto-commit. performMove sets
                % pendingMove; commitPendingMove finishes the handoff.
                this.performMove(head.myFrom(1), head.myFrom(2), head.myTo(1), head.myTo(2));
                if ~isempty(this.pendingMove)
                    this.commitPendingMove();
                end
                fired = true;
            end

            % Repaint any remaining queued premoves (their tints
            % were cleared above before the move that fired).
            this.paintAllPremoveHighlights();
        end

        function updateActionButtons(this)
            if isempty(this.endTurnButton) || ~ishandle(this.endTurnButton); return; end

            review       = this.isReviewMode;
            havePending  = ~isempty(this.pendingMove);
            haveNet      = ~isempty(this.netGame);
            havePremoves = ~isempty(this.premoveQueue);

            % Slot layout (see createGUI for pixel positions):
            %   slot 1 (x=655): End Turn  OR  Clear Pre  (mutually exclusive)
            %   slot 2 (x=735): Undo                     (only with pending move)
            showEndTurn  = havePending && ~review;
            showUndo     = havePending && ~review;
            showClearPre = havePremoves && ~havePending && ~review;

            set(this.endTurnButton,        'Visible', onoff(showEndTurn));
            set(this.undoButton,           'Visible', onoff(showUndo));
            set(this.clearPremovesButton,  'Visible', onoff(showClearPre));

            % Refresh is unsafe while a pending move exists (would
            % wipe our visual move). Disable in that case. Also off
            % in review mode -- the network is closed.
            if havePending || review
                set(this.refreshButton, 'Enable', 'off');
            else
                set(this.refreshButton, 'Enable', this.refreshEnableFlag());
            end

            % Pause is meaningless in review mode -- the clock isn't
            % running. Disable explicitly so it doesn't look active.
            if ~isempty(this.pauseButton) && ishandle(this.pauseButton) && review
                set(this.pauseButton, 'Enable', 'off');
            end

            % Replay & History both need a non-empty history. Replay
            % is also gated on having a lastMove and on the board not
            % being mid-apply. History stays enabled even with a
            % pending move (it's read-only and opens its own figure).
            histState = this.currentHistoryState();
            haveHist = ~isempty(histState) ...
                       && isfield(histState, 'history') ...
                       && ~isempty(histState.history);
            haveLast = ~isempty(histState) ...
                       && isfield(histState, 'lastMove') ...
                       && ~isempty(histState.lastMove);
            canReplay = haveLast && ~havePending ...
                        && ~this.suppressInput && ~this.isRewound() && ~review;
            if ~isempty(this.replayButton) && ishandle(this.replayButton)
                set(this.replayButton,  'Enable', onoff(canReplay));
            end
            if ~isempty(this.historyButton) && ishandle(this.historyButton)
                set(this.historyButton, 'Enable', onoff(haveHist));
            end

            % Rewind controls.
            nHist = 0;
            if haveHist; nHist = numel(histState.history); end
            rewound = this.isRewound();
            % Prev is enabled when there's somewhere to step back to.
            % From live, that means nHist >= 2 (step to second-to-last).
            % From rewind, that means rewindIndex > 1.
            if rewound
                canPrev = this.rewindIndex > 1;
            else
                canPrev = nHist >= 2;
            end
            canNext = rewound;     % can always step forward (stepping past end goes Live)
            % Live is enabled while rewound, OR while in review mode
            % with an active variation from the final position (so
            % the user can reset to the actual final position).
            canLive = rewound || (review && this.reviewVariationActive);
            % Pending move locks everything rewind-related too -- we
            % never want to strand the mover in a rewound view with
            % their uncommitted move somewhere on the actual board.
            if havePending
                canPrev = false; canNext = false; canLive = false;
            end
            if ~isempty(this.prevMoveButton) && ishandle(this.prevMoveButton)
                set(this.prevMoveButton, 'Enable', onoff(canPrev));
            end
            if ~isempty(this.nextMoveButton) && ishandle(this.nextMoveButton)
                set(this.nextMoveButton, 'Enable', onoff(canNext));
            end
            if ~isempty(this.liveButton) && ishandle(this.liveButton)
                set(this.liveButton, 'Enable', onoff(canLive));
            end

            if review
                this.rememberAnalysisEnginePathFromGame();
            end
            canAnalyze = review && ~havePending && ~this.suppressInput && ~this.analysisBusy;
            canPlayBest = canAnalyze && ~isempty(this.analysisBestMove) ...
                && isstruct(this.analysisBestMove) && isfield(this.analysisBestMove, 'uci') ...
                && ~isempty(this.analysisBestMove.uci) ...
                && (isempty(this.analysisBestFen) || strcmp(char(this.analysisBestFen), char(this.currentFenForAnalysis())));
            if ~isempty(this.analysisAnalyzeButton) && ishandle(this.analysisAnalyzeButton)
                set(this.analysisAnalyzeButton, 'Enable', onoff(canAnalyze));
            end
            if ~isempty(this.analysisEngineButton) && ishandle(this.analysisEngineButton)
                set(this.analysisEngineButton, 'Enable', onoff(review && ~this.analysisBusy));
            end
            if ~isempty(this.analysisPlayButton) && ishandle(this.analysisPlayButton)
                set(this.analysisPlayButton, 'Enable', onoff(canPlayBest));
            end
            if ~isempty(this.analysisText) && ishandle(this.analysisText) && ~review
                set(this.analysisText, 'String', {'Use Review Game after the game ends.', ...
                    'Then step to any position and click Analyze.'}, 'Value', 1);
            end

            function s = onoff(b)
                if b; s = 'on'; else; s = 'off'; end
            end
        end

        function onReplayLastMoveClicked(this)
            if ~isempty(this.pendingMove); return; end
            if this.suppressInput; return; end
            if ~isempty(this.rewindIndex); return; end  % ambiguous while rewound
            % Reuse the existing flash routine -- no state change,
            % just a brief two-square highlight on from/to.
            this.flashLastMove(this.currentHistoryState());
        end

        % ---------------------------------------------------------------
        % Rewind (view past positions)
        % ---------------------------------------------------------------
        % Enters rewind mode by rendering the board from a past
        % history entry's stored snapshot. Gameplay is locked while
        % rewound; the auto-poll keeps running and updates the cached
        % state, but the board pixels stay on the rewound position
        % until the user explicitly exits (Live button, or clicking
        % the newest history row).
        %
        % Entering rewind clears any queued premoves (a premove
        % against a past position is meaningless).

        function onPrevMoveClicked(this)
            if ~isempty(this.pendingMove); return; end
            state = this.currentHistoryState();
            if ~isfield(state, 'history') || isempty(state.history); return; end

            if isempty(this.rewindIndex)
                % Live -> jump to the second-to-last move (so you see
                % the position BEFORE the last move was played).
                target = numel(state.history) - 1;
            else
                target = this.rewindIndex - 1;
            end

            if target < 1
                % Before history{1} is the initial position. Represent
                % that with rewindIndex = 0 (special: no stored snapshot,
                % we render from state.history{1}'s pre-image by walking
                % back -- simpler to just forbid going before move 1).
                return;
            end
            this.enterRewindAt(target);
        end

        function onNextMoveClicked(this)
            if ~isempty(this.pendingMove); return; end
            if isempty(this.rewindIndex); return; end   % already live
            state = this.currentHistoryState();
            if ~isfield(state, 'history') || isempty(state.history); return; end
            target = this.rewindIndex + 1;
            if target >= numel(state.history)
                % Stepping past the last history entry puts us back live.
                this.onLiveClicked();
                return;
            end
            this.enterRewindAt(target);
        end

        function onLiveClicked(this)
            if ~isempty(this.pendingMove); return; end
            wasRewound = this.isRewound();
            wasVariation = this.isReviewMode && this.reviewVariationActive;
            if ~wasRewound && ~wasVariation; return; end   % nothing to reset
            this.rewindIndex = [];
            this.reviewVariationActive = false;
            this.clearAnalysisBestMove({'Final position loaded.', ...
                'Click Analyze Position for Stockfish best move.'});
            % Re-render from the current cached state, which may be
            % newer than what we were viewing. suppressInput guards
            % the click handlers during the rebuild.
            this.suppressInput = true;
            cleaner = onCleanup(@() this.unsuppressInput());
            liveState = this.currentHistoryState();
            GameState.applyToModel(liveState, ...
                this.chessBoardModel, this.gameController, this);
            clear cleaner;
            % Flash the true last move so the user's eye finds it.
            this.flashLastMove(liveState);
            % Repaint any premove highlights (queue was preserved
            % while rewound only if we exited via Live -- entering
            % rewind had already cleared them). In review mode the
            % queue is empty.
            if ~this.isReviewMode
                this.paintAllPremoveHighlights();
            end
            this.updateStatusBar();
            this.updateActionButtons();
        end

        function enterRewindAt(this, idx)
            % Renders the board from history{idx}'s stored snapshot
            % and switches to rewind mode. Clears any queued premoves
            % on the first entry into rewind (not on each step).
            state = this.currentHistoryState();
            if isempty(state) || ~isfield(state, 'history') || idx < 1 || idx > numel(state.history)
                return;
            end
            entry = state.history{idx};
            if ~isstruct(entry) || ~isfield(entry, 'boardAfter')
                % Pre-snapshot history entry -- older game, can't
                % rewind to here. Tell the user once and bail.
                if isempty(this.rewindIndex)
                    try
                        msgbox(['This move was played before snapshots were recorded ' ...
                                'in this game. Only newer moves can be rewound to.'], ...
                               'Rewind unavailable', 'warn', 'non-modal');
                    catch
                    end
                end
                return;
            end

            wasAlreadyRewound = ~isempty(this.rewindIndex);

            % Entering rewind for the first time -- clear premove
            % queue. Don't do this on every step or it'd fight the
            % no-op case.
            if ~wasAlreadyRewound
                if ~isempty(this.premoveQueue)
                    this.clearPremoveQueueHighlights();
                    this.premoveQueue = {};
                end
                % Clear selection + pending-move highlight (pending
                % move shouldn't exist here since we're guarded, but
                % selection might).
                this.clearSelection();
            end

            this.rewindIndex = idx;
            % Entering a (new) rewind position discards any active
            % variation -- the user is starting fresh from here.
            this.reviewVariationActive = false;
            this.clearAnalysisBestMove({'Historical position loaded.', ...
                'Click Analyze Position to see Stockfish''s recommendation.'});

            % Build a synthetic state for applyToModel. We only need
            % the fields it reads: board, moved, enPassantInfo, and
            % moveNumber (used to set gameController.round, which we
            % save/restore so live logic isn't corrupted).
            roundBefore = this.gameController.round;
            synth = struct();
            synth.board         = entry.boardAfter;
            synth.moved         = entry.movedAfter;
            if isfield(entry, 'enPassantInfoAfter')
                synth.enPassantInfo = entry.enPassantInfoAfter;
            else
                synth.enPassantInfo = [];
            end
            synth.moveNumber    = entry.moveNumber + 1;
            synth.timer         = state.timer;   % keep current timer display

            this.suppressInput = true;
            cleaner = onCleanup(@() this.unsuppressInput());
            GameState.applyToModel(synth, this.chessBoardModel, ...
                this.gameController, this);
            clear cleaner;

            if this.isReviewMode
                % In review mode we KEEP applyToModel's setRound side
                % effect: round = entry.moveNumber + 1, which encodes
                % "whose turn next" via the existing whoPlays parity.
                % Black just moved at round 8 -> round 9 (odd -> white)
                % White just moved at round 7 -> round 8 (even -> black)
                % This is exactly what we want for variation play.
            else
                % View-only: undo applyToModel's setRound side-effect
                % so live gameplay isn't corrupted.
                this.gameController.setRound(roundBefore);
            end

            % Flash the from/to of this move so the user sees which
            % move landed them here.
            synthFlash = struct('lastMove', entry);
            this.flashLastMove(synthFlash);

            this.updateStatusBar();
            this.updateActionButtons();
            this.syncHistoryListboxSelection();
        end

        function tf = isRewound(this)
            tf = ~isempty(this.rewindIndex);
        end

        function syncHistoryListboxSelection(this)
            % If the history viewer is open, move its selection to
            % match rewindIndex (or the last row when live).
            if isempty(this.historyFigure) || ~ishandle(this.historyFigure); return; end
            lb = findobj(this.historyFigure, 'Tag', 'historyListbox');
            if isempty(lb); return; end
            ud = get(lb, 'UserData');
            if isempty(ud); return; end
            history = ud{1};
            if isempty(history); return; end
            if isempty(this.rewindIndex)
                target = numel(history);
            else
                target = this.rewindIndex;
            end
            try
                set(lb, 'Value', max(1, min(target, numel(history))));
            catch
            end
        end

        function onShowHistoryClicked(this)
            state = this.currentHistoryState();
            if ~isempty(state) ...
               && isfield(state, 'history') ...
               && ~isempty(state.history)
                this.openHistoryViewer(state.history);
            end
        end

        % Opens (or refocuses, if already open) a separate figure
        % listing all moves played so far. Clicking a row enters
        % rewind mode at that move. Clicking the newest row exits
        % rewind (returns to live).
        function openHistoryViewer(this, history)
            % If a viewer is already open, refresh its listbox in
            % place rather than spawning a second figure.
            if ~isempty(this.historyFigure) && ishandle(this.historyFigure)
                lb = findobj(this.historyFigure, 'Tag', 'historyListbox');
                if ~isempty(lb)
                    set(lb, 'String', this.formatHistoryRows(history), ...
                            'UserData', {history});
                end
                this.syncHistoryListboxSelection();
                figure(this.historyFigure);
                return;
            end
            f = figure('Name', 'Move History', ...
                'Position', [320 200 380 480], ...
                'MenuBar', 'none', 'NumberTitle', 'off', ...
                'Color', [1 1 1], 'Resize', 'off', ...
                'CloseRequestFcn', @(src,~) this.onHistoryFigureClosed(src));
            this.historyFigure = f;

            uicontrol(f, 'Style','text', ...
                'String', 'Click any move to view that position.', ...
                'FontSize', 10, 'HorizontalAlignment','left', ...
                'BackgroundColor', [1 1 1], ...
                'Position', [12 446 360 22]);
            uicontrol(f, 'Style','listbox', ...
                'Tag', 'historyListbox', ...
                'FontName', 'Courier New', 'FontSize', 11, ...
                'String', this.formatHistoryRows(history), ...
                'UserData', {history}, ...
                'Position', [12 12 356 430], ...
                'Callback', @(src,~) this.onHistoryRowClicked(src));
            this.syncHistoryListboxSelection();
        end

        function onHistoryFigureClosed(this, src)
            try
                delete(src);
            catch
            end
            this.historyFigure = [];
        end

        function onHistoryRowClicked(this, lb)
            if ~isempty(this.pendingMove); return; end
            ud = get(lb, 'UserData');
            if isempty(ud); return; end
            history = ud{1};
            idx = get(lb, 'Value');
            if idx < 1 || idx > numel(history); return; end
            % Clicking the newest row means "go back to live." Any
            % other row enters (or moves) rewind.
            if idx == numel(history)
                if ~isempty(this.rewindIndex)
                    this.onLiveClicked();
                else
                    % Already live and latest row clicked -- just
                    % flash the most recent move as a hint.
                    this.flashLastMove(this.currentHistoryState());
                end
            else
                this.enterRewindAt(idx);
            end
        end

        function rows = formatHistoryRows(~, history)
            n = numel(history);
            rows = cell(n, 1);
            files = 'abcdefgh';
            for i = 1:n
                mv = history{i};
                if ~isstruct(mv)
                    rows{i} = sprintf('%3d.  ?', i);
                    continue;
                end
                colorChar = '?';
                if isfield(mv, 'color') && ~isempty(mv.color)
                    if mv.color == 'w'; colorChar = 'W'; else; colorChar = 'B'; end
                end
                pieceLetter = '';
                if isfield(mv, 'piece') && mv.piece ~= 'P'
                    pieceLetter = mv.piece;
                end
                % from/to are stored as [rank file] (1-indexed).
                fromSq = ' ?';
                toSq   = ' ?';
                if isfield(mv,'from') && numel(mv.from)==2
                    fromSq = sprintf('%c%d', files(mv.from(2)), mv.from(1));
                end
                if isfield(mv,'to') && numel(mv.to)==2
                    toSq = sprintf('%c%d', files(mv.to(2)), mv.to(1));
                end
                separator = '-';
                if isfield(mv,'capture') && mv.capture
                    separator = 'x';
                end
                annot = '';
                if isfield(mv,'castle') && mv.castle
                    if isfield(mv,'castleSide') && mv.castleSide == 'k'
                        token = 'O-O';
                    else
                        token = 'O-O-O';
                    end
                else
                    token = sprintf('%s%s%s%s', pieceLetter, fromSq, separator, toSq);
                end
                if isfield(mv,'promotion') && mv.promotion && ~strcmp(token,'O-O') && ~strcmp(token,'O-O-O')
                    if isfield(mv,'piece'); token = sprintf('%s=%c', token, mv.piece); end
                end
                if isfield(mv,'enPassant') && mv.enPassant
                    annot = ' ep';
                end
                if isfield(mv,'checkmate') && mv.checkmate
                    token = [token '#'];
                elseif isfield(mv,'check') && mv.check
                    token = [token '+'];
                end
                if isfield(mv,'draw') && mv.draw
                    if isfield(mv,'drawRepetition') && mv.drawRepetition
                        annot = [annot ' 1/2-1/2 rep'];
                    elseif isfield(mv,'stalemate') && mv.stalemate
                        annot = [annot ' 1/2-1/2 stalemate'];
                    else
                        annot = [annot ' 1/2-1/2'];
                    end
                elseif isfield(mv,'stalemate') && mv.stalemate
                    annot = [annot ' 1/2-1/2 stalemate'];
                end
                num = i;
                if isfield(mv,'moveNumber') && ~isempty(mv.moveNumber)
                    num = mv.moveNumber;
                end
                rows{i} = sprintf('%3d.  %s  %-10s%s', num, colorChar, token, annot);
            end
        end

        function onRefreshClicked(this, isAutoRefresh)
            if nargin < 2; isAutoRefresh = false; end
            if isempty(this.netGame); return; end
            if this.isReviewMode; return; end   % network is closed in review mode
            if ~isempty(this.pendingMove)
                % Shouldn't happen -- button is disabled -- but guard
                % anyway; refreshing here would wipe the pending move.
                return;
            end
            this.clearSelection();

            wasRewound = this.isRewound();

            % When live, clear premove tints before applyToModel so
            % any mismatched queue can be discarded and survivors
            % repainted after. When rewound, the board pixels aren't
            % changing (we won't call applyToModel), so we leave
            % tints alone -- but the queue is empty anyway because
            % entering rewind clears it.
            if ~wasRewound
                this.clearPremoveQueueHighlights();
            end

            prevState = this.netGame.lastSeenState;
            try
                state = this.netGame.load();
            catch err
                if ~wasRewound
                    % Load failed -- restore the tints we just cleared so
                    % the UI is unchanged.
                    this.paintAllPremoveHighlights();
                end
                errordlg(err.message, 'Refresh failed', 'modal');
                return;
            end
            boardUpdated = isempty(prevState) || state.moveNumber ~= prevState.moveNumber;
            notifyAutoMoveArrival = isAutoRefresh ...
                && this.shouldNotifyAutoMoveArrival(prevState, state, boardUpdated);
            if ~isAutoRefresh
                this.autoNoMovePollCount = 0;
            end

            if wasRewound
                % Board rewind path: state is now cached (netGame.load
                % updated lastSeenState). We don't apply it to the GUI
                % -- the user is deliberately looking at a past
                % position. Don't flash, don't notify, don't fire
                % premoves; all of that will happen when they click
                % Live. Do refresh the history viewer so the new row
                % shows up.
                %
                % Exception: if checkmate just landed, the game is
                % over -- auto-exit rewind so the user sees the
                % final position and gets the notification.
                terminalArrived = this.didStateEnterTerminal(prevState, state, boardUpdated);
                if terminalArrived
                    this.onLiveClicked();
                    this.notifyForTerminalState(state);
                    this.resetAutoPoll();
                    return;
                end
                if ~isempty(this.historyFigure) && ishandle(this.historyFigure) ...
                   && isfield(state, 'history') && ~isempty(state.history)
                    this.openHistoryViewer(state.history);
                end
                this.updateStatusBar();
                this.updateActionButtons();
                this.resetAutoPoll();
                return;
            end

            this.suppressInput = true;
            c = onCleanup(@() this.unsuppressInput());
            GameState.applyToModel(state, this.chessBoardModel, ...
                this.gameController, this);
            clear c;
            if boardUpdated
                this.flashLastMove(state);
            end
            this.syncClockAfterBoardLoad(prevState, state, boardUpdated);

            % Check no longer produces a popup. The status bar/history
            % still carry the check state, and a warning is shown only
            % when the checked player attempts a move that does not
            % resolve their own check. Checkmate remains terminal.
            if this.didStateEnterTerminal(prevState, state, boardUpdated)
                this.notifyForTerminalState(state);
            end

            if boardUpdated
                this.autoNoMovePollCount = 0;
            end

            % If the opponent just moved and we have a queued premove
            % predicting that move, fire it. tryFirePremove also
            % handles the mismatch case (queue discarded) and the
            % illegal-response case (queue discarded).
            if boardUpdated
                this.tryFirePremove(state);
            end

            if notifyAutoMoveArrival && ~this.isTerminalStatus(this.currentGameStatus()) ...
                    && ~isempty(this.netGame) && this.netGame.isMyTurn()
                this.notifyAutoMoveArrival();
            end

            % Whatever survived (the firing cleared the one that
            % fired; the rest stays queued) is repainted here.
            this.paintAllPremoveHighlights();

            this.updateStatusBar();
            this.updateActionButtons();

            % If the history viewer is open, refresh its contents so
            % the new move shows up immediately. Cheap: just rebuilds
            % the listbox strings from the cached state.
            if ~isempty(this.historyFigure) && ishandle(this.historyFigure) ...
               && isfield(state, 'history') && ~isempty(state.history)
                this.openHistoryViewer(state.history);
            end

            % Push the next auto-poll tick out by a fresh jittered
            % interval. Otherwise a user-driven Refresh followed by
            % a tick that was already almost due would produce two
            % file reads within a second of each other.
            this.resetAutoPoll();
        end



        function noteAutoPollWithoutMove(this)
            if isempty(this.netGame) || ~this.isUnlimitedNetworkGame()
                this.autoNoMovePollCount = 0;
                return;
            end
            if this.netGame.isMyTurn() || this.isGamePaused() || this.isTerminalStatus(this.currentGameStatus())
                this.autoNoMovePollCount = 0;
                return;
            end
            this.autoNoMovePollCount = this.autoNoMovePollCount + 1;
        end

        function tf = shouldNotifyAutoMoveArrival(this, prevState, state, boardUpdated)
            tf = false;
            if isempty(this.netGame) || ~boardUpdated || ~this.isUnlimitedNetworkGame()
                return;
            end
            if this.autoNoMovePollCount <= this.LONG_WAIT_POLL_THRESHOLD
                return;
            end
            if isempty(prevState) || ~isfield(prevState, 'turn') || ~isfield(state, 'turn')
                return;
            end
            opponentColor = this.oppositeColor(this.netGame.myColor);
            prevTurn = char(prevState.turn);
            newTurn  = char(state.turn);
            myColor  = char(this.netGame.myColor);
            tf = strcmp(prevTurn, opponentColor) && strcmp(newTurn, myColor);
            if tf && isfield(state, 'lastMove') && ~isempty(state.lastMove) && isfield(state.lastMove, 'color')
                tf = strcmp(char(state.lastMove.color), opponentColor);
            end
        end

        function tf = isUnlimitedNetworkGame(this)
            tf = false;
            if isempty(this.netGame)
                return;
            end
            timerState = this.currentTimerState();
            tf = isempty(timerState) || ~isfield(timerState, 'enabled') || ~timerState.enabled;
        end

        function notifyAutoMoveArrival(this)
            if isempty(this.netGame) || ~ishandle(this.figureHandle)
                return;
            end
            myStr = 'White';
            if this.netGame.myColor == 'b'; myStr = 'Black'; end
            msgbox(sprintf('Your opponent moved. It is now your turn as %s.', myStr), ...
                'Move received', 'help');
        end

        function handleNetworkInitialOpen(this)
            if isempty(this.netGame)
                return;
            end
            timerState = this.currentTimerState();
            if ~timerState.enabled || ~isempty(timerState.expiredColor) || this.isGamePaused()
                this.refreshTimerLabels();
                this.updatePauseButton();
                return;
            end

            firstOpenForMe = ~GameState.hasColorOpened(timerState, this.netGame.myColor);
            shouldPersist = false;
            if firstOpenForMe
                timerState = GameState.setColorOpened(timerState, this.netGame.myColor, true);
                shouldPersist = true;
            end

            % Do NOT start the clock merely because the first player
            % opened a hosted game. The game remains active/playable, but
            % the initial clock stays idle until White commits the first
            % move. After move 1, the normal refresh/sync path starts the
            % side-to-move clock.
            isInitialPosition = this.netGame.lastSeenState.moveNumber == 1;
            if isfield(this.netGame.lastSeenState, 'history')
                isInitialPosition = isInitialPosition && isempty(this.netGame.lastSeenState.history);
            end

            shouldStartNow = false;
            if ~isInitialPosition && firstOpenForMe && this.netGame.isMyTurn() ...
                    && strcmp(this.netGame.lastSeenState.status, 'active')
                shouldStartNow = true;
            elseif ~isInitialPosition && this.netGame.isMyTurn() ...
                    && strcmp(this.netGame.lastSeenState.status, 'active')
                shouldStartNow = true;
            end

            if shouldStartNow
                timerState.running = true;
                timerState.paused = false;
                timerState.pausedBy = '';
                timerState.activeColor = this.netGame.myColor;
                timerState.startedAt = GameState.nowISO();
                shouldPersist = true;
            end

            this.applyTimerStateToCurrentContext(timerState);
            if shouldPersist
                try
                    this.netGame.save(this.netGame.lastSeenState);
                catch
                end
            end

            if shouldStartNow
                this.resumeTimerIfNeeded();
            else
                this.refreshTimerLabels();
                this.updatePauseButton();
            end
        end

        function unsuppressInput(this)
            this.suppressInput = false;
        end

        function redrawAfterStateLoad(this, state)
            if nargin < 2 || isempty(state); return; end
            % While rewound, the "state" we're rendering is a
            % synthetic past snapshot; don't let it write through to
            % the live timer state. The caller (enterRewindAt)
            % handles flashing / highlights itself.
            if this.isRewound()
                this.refreshTimerLabels();
                this.updateCapturedPiecesPanel();
                return;
            end
            this.applyTimerStateToCurrentContext(state.timer);
            this.refreshTimerLabels();
            % applyToModel wipes CData/UserData on every square but
            % leaves square backgrounds alone. Even so, the caller
            % (onRefreshClicked) already cleared premove tints before
            % applyToModel so that any mismatched queue could be
            % discarded; we re-paint surviving premoves from here
            % only if that path isn't the one that drove us here
            % (e.g. initial load, failed-write rollback).
            if ~isempty(this.premoveQueue)
                this.paintAllPremoveHighlights();
            end
            if ~isempty(this.pendingMove)
                this.paintPendingMoveHighlight();
            end
            this.updateCapturedPiecesPanel();
            this.updateActionButtons();
        end

        function flashLastMove(this, state)
            if isempty(state) || ~isfield(state,'lastMove') || isempty(state.lastMove)
                return;
            end
            mv = state.lastMove;
            if ~isstruct(mv); return; end
            fromBtn = this.chessBoardModel.chessBoardBoxes(mv.from(2), mv.from(1)).button;
            toBtn   = this.chessBoardModel.chessBoardBoxes(mv.to(2),   mv.to(1)).button;
            if ~ishandle(fromBtn) || ~ishandle(toBtn); return; end
            fromOrig = get(fromBtn, 'BackgroundColor');
            toOrig   = get(toBtn,   'BackgroundColor');
            set(fromBtn, 'BackgroundColor', this.COLOR_LASTMOVE);
            set(toBtn,   'BackgroundColor', this.COLOR_LASTMOVE);
            pause(0.6);
            if ishandle(fromBtn); set(fromBtn, 'BackgroundColor', fromOrig); end
            if ishandle(toBtn);   set(toBtn,   'BackgroundColor', toOrig);   end
        end

        function updateStatusBar(this)
            if ~ishandle(this.statusText); return; end
            timerState = this.currentTimerState();
            if this.isReviewMode
                % Review mode preempts everything -- the game is over,
                % the clock isn't running, and we're exploring.
                if this.isRewound()
                    s = this.currentHistoryState();
                    nHist = 0;
                    if isfield(s, 'history'); nHist = numel(s.history); end
                    if this.reviewVariationActive
                        sideStr = 'White';
                        if this.gameController.whoPlays() == 'b'; sideStr = 'Black'; end
                        msg = sprintf('Review var. %d/%d  --  %s to move  (Prev/Next discards)', ...
                            this.rewindIndex, nHist, sideStr);
                    else
                        msg = sprintf('Review move %d/%d  --  click any piece to explore', ...
                            this.rewindIndex, nHist);
                    end
                else
                    % Live position in review mode = the final
                    % position. Variation flag is sticky here too if
                    % the user has already played from the final.
                    if this.reviewVariationActive
                        sideStr = 'White';
                        if this.gameController.whoPlays() == 'b'; sideStr = 'Black'; end
                        msg = sprintf('Review final variation  --  %s to move', sideStr);
                    else
                        msg = 'Review final  --  click a piece, or use < > to step through history';
                    end
                end
            elseif ~isempty(timerState) && isfield(timerState, 'expiredColor') && ~isempty(timerState.expiredColor)
                loser = 'White'; if timerState.expiredColor == 'b'; loser = 'Black'; end
                msg = sprintf('%s flag fell', loser);
            elseif this.isTerminalStatus(this.currentGameStatus())
                status = this.currentGameStatus();
                if strcmp(status, 'checkmate')
                    msg = 'Checkmate';
                else
                    msg = ['Draw  --  ' this.drawReasonForStatus(status)];
                end
            elseif this.isGamePaused()
                if isempty(this.netGame)
                    msg = 'Game paused';
                else
                    s = this.netGame.lastSeenState;
                    whoPaused = '';
                    if isfield(timerState, 'pausedBy') && ~isempty(timerState.pausedBy)
                        whoPaused = 'White'; if timerState.pausedBy == 'b'; whoPaused = 'Black'; end
                    end
                    myStr = 'White'; if this.netGame.myColor == 'b'; myStr = 'Black'; end
                    if isempty(whoPaused)
                        msg = sprintf('You are %s  --  game paused  (move %d)', myStr, s.moveNumber);
                    else
                        msg = sprintf('You are %s  --  game paused by %s  (move %d)', myStr, whoPaused, s.moveNumber);
                    end
                end
            elseif this.isRewound()
                % Rewind status takes precedence over turn info --
                % the user is viewing history, not playing live.
                s = this.currentHistoryState();
                nHist = 0;
                if isfield(s, 'history'); nHist = numel(s.history); end
                newSince = max(0, nHist - this.rewindIndex);
                if newSince == 0
                    msg = sprintf('Viewing move %d of %d  --  click Live to return', ...
                        this.rewindIndex, nHist);
                else
                    msg = sprintf('Viewing move %d of %d  --  %d new move%s since  --  click Live to return', ...
                        this.rewindIndex, nHist, newSince, ternary(newSince==1,'','s'));
                end
            elseif ~isempty(this.pendingMove)
                moverStr = 'White';
                if this.pendingMove.moverColor == 'b'; moverStr = 'Black'; end
                msg = sprintf('%s: move pending  --  End Turn to send, Undo to take back', moverStr);
            elseif isempty(this.netGame)
                if this.isStockfishGame()
                    humanStr = 'White'; if this.playerColor == 'b'; humanStr = 'Black'; end
                    botColor = this.oppositeColor(this.playerColor);
                    botStr = 'White'; if botColor == 'b'; botStr = 'Black'; end
                    if this.botThinking
                        msg = sprintf('You are %s  --  Stockfish (%s) thinking...', humanStr, botStr);
                    elseif this.gameController.whoPlays() == this.playerColor
                        msg = sprintf('You are %s  --  YOUR TURN', humanStr);
                    else
                        msg = sprintf('You are %s  --  Stockfish (%s) to move', humanStr, botStr);
                    end
                elseif this.gameController.whoPlays() == 'w'
                    msg = 'White to move';
                else
                    msg = 'Black to move';
                end
            else
                s = this.netGame.lastSeenState;
                myStr = 'White'; if this.netGame.myColor == 'b'; myStr = 'Black'; end
                if this.netGame.isMyTurn()
                    msg = sprintf('You are %s  --  YOUR TURN  (move %d)', myStr, s.moveNumber);
                else
                    nQueued = numel(this.premoveQueue);
                    cap     = this.PREMOVE_QUEUE_MAX;
                    selPrefix = '';
                    if ~isempty(this.selectedFile)
                        selPrefix = '  --  premove src picked, click destination';
                    elseif nQueued >= cap
                        selPrefix = sprintf('  --  premove queue full (%d)', cap);
                    end
                    if nQueued == 0
                        msg = sprintf('You are %s  --  waiting for opponent  (move %d, auto-syncing)%s', ...
                            myStr, s.moveNumber, selPrefix);
                    else
                        msg = sprintf('You are %s  --  waiting  (move %d, %d premove%s queued)%s', ...
                            myStr, s.moveNumber, nQueued, ternary(nQueued==1,'','s'), selPrefix);
                    end
                end
                if ~strcmp(s.status, 'active')
                    msg = sprintf('%s  |  %s', msg, upper(s.status));
                end
            end
            set(this.statusText, 'String', msg);
            this.updateCheckMarkers();
            this.refreshTimerLabels();
            this.updatePauseButton();
            this.updateActionButtons();

            function s = ternary(cond, a, b)
                if cond; s = a; else; s = b; end
            end
        end

        function flag = refreshEnableFlag(this)
            if isempty(this.netGame); flag = 'off'; else; flag = 'on'; end
        end



        function tf = isGamePaused(this)
            timerState = this.currentTimerState();
            tf = ~isempty(timerState) && isfield(timerState, 'paused') && timerState.paused;
            if ~tf && ~isempty(this.netGame)
                tf = isfield(this.netGame.lastSeenState, 'status') && strcmp(this.netGame.lastSeenState.status, 'paused');
            end
        end

        function updatePauseButton(this)
            if isempty(this.pauseButton) || ~ishandle(this.pauseButton)
                return;
            end
            timerState = this.currentTimerState();
            if ~timerState.enabled || ~isempty(timerState.expiredColor) ...
                    || this.isTerminalStatus(this.currentGameStatus())
                set(this.pauseButton, 'Enable', 'off', 'String', 'Pause');
                return;
            end
            if this.isGamePaused()
                label = 'Resume';
            else
                label = 'Pause';
            end
            enableState = 'on';
            if ~isempty(this.netGame) && ~strcmp(this.netGame.lastSeenState.status, 'active') && ~strcmp(this.netGame.lastSeenState.status, 'paused')
                enableState = 'off';
            end
            set(this.pauseButton, 'Enable', enableState, 'String', label);
        end

        function onPauseResumeClicked(this)
            timerState = this.currentTimerState();
            if ~timerState.enabled || ~isempty(timerState.expiredColor) ...
                    || this.isTerminalStatus(this.currentGameStatus())
                this.updatePauseButton();
                return;
            end
            nowIso = GameState.nowISO();
            if this.isGamePaused()
                timerState.running = true;
                timerState.paused = false;
                timerState.pausedBy = '';
                if isempty(timerState.activeColor)
                    if isempty(this.netGame)
                        timerState.activeColor = this.gameController.whoPlays();
                    else
                        timerState.activeColor = this.netGame.lastSeenState.turn;
                    end
                end
                timerState.startedAt = nowIso;
                this.applyTimerStateToCurrentContext(timerState);
                if isempty(this.netGame)
                    this.resumeTimerIfNeeded();
                else
                    this.netGame.setCachedTimer(timerState);
                    this.netGame.setCachedStatus('active');
                    try
                        this.netGame.save(this.netGame.lastSeenState);
                        this.resumeTimerIfNeeded();
                    catch err
                        timerState.running = false;
                        timerState.paused = true;
                        timerState.pausedBy = this.netGame.myColor;
                        timerState.startedAt = '';
                        this.applyTimerStateToCurrentContext(timerState);
                        this.netGame.setCachedStatus('paused');
                        errordlg(err.message, 'Resume failed', 'modal');
                    end
                end
            else
                if timerState.running
                    timerState = GameState.applyElapsedToTimer(timerState, nowIso);
                end
                timerState.running = false;
                timerState.paused = true;
                timerState.startedAt = '';
                if isempty(this.netGame)
                    timerState.pausedBy = '';
                else
                    timerState.pausedBy = this.netGame.myColor;
                end
                this.applyTimerStateToCurrentContext(timerState);
                this.stopMoveTimer();
                if ~isempty(this.netGame)
                    this.netGame.setCachedTimer(timerState);
                    this.netGame.setCachedStatus('paused');
                    try
                        this.netGame.save(this.netGame.lastSeenState);
                    catch err
                        timerState.running = true;
                        timerState.paused = false;
                        timerState.pausedBy = '';
                        timerState.startedAt = nowIso;
                        this.applyTimerStateToCurrentContext(timerState);
                        this.netGame.setCachedStatus('active');
                        this.resumeTimerIfNeeded();
                        errordlg(err.message, 'Pause failed', 'modal');
                    end
                end
            end
            this.refreshTimerLabels();
            this.updateStatusBar();
        end

        function state = currentStateStruct(this)
            if isempty(this.netGame)
                state = struct('timer', this.currentTimerState(), 'status', this.localGameStatus, ...
                    'turn', this.gameController.whoPlays(), 'moveNumber', this.gameController.round);
            else
                state = this.netGame.lastSeenState;
            end
        end

        function timerState = currentTimerState(this)
            if isempty(this.netGame)
                if isempty(this.localTimerState)
                    timerState = GameState.makeTimerState(false, 10);
                else
                    timerState = GameState.normalizeTimerState(this.localTimerState);
                end
            else
                if isfield(this.netGame.lastSeenState, 'timer')
                    timerState = GameState.normalizeTimerState(this.netGame.lastSeenState.timer);
                else
                    timerState = GameState.makeTimerState(false, 10);
                end
            end
        end

        function applyTimerStateToCurrentContext(this, timerState)
            timerState = GameState.normalizeTimerState(timerState);
            if isempty(this.netGame)
                this.localTimerState = timerState;
                this.timerExpiredLocal = ~isempty(timerState.expiredColor);
            else
                this.netGame.setCachedTimer(timerState);
            end
        end

        function tf = isClockExpired(this)
            timerState = this.currentTimerState();
            tf = ~isempty(timerState) && isfield(timerState, 'expiredColor') && ~isempty(timerState.expiredColor);
        end

        function nextTimerState = timerStateAfterCompletedMove(this, prevTimerState, moverColor)
            nextTimerState = GameState.normalizeTimerState(prevTimerState);
            if ~nextTimerState.enabled
                return;
            end
            nextTimerState = GameState.applyElapsedToTimer(nextTimerState, GameState.nowISO());
            if ~isempty(nextTimerState.expiredColor)
                return;
            end
            nextTimerState.activeColor = this.oppositeColor(moverColor);
            nextTimerState.running = false;
            nextTimerState.paused = false;
            nextTimerState.pausedBy = '';
            nextTimerState.startedAt = '';
        end

        function c = oppositeColor(~, c0)
            c = 'w';
            if c0 == 'w'
                c = 'b';
            end
        end

        function syncClockAfterBoardLoad(this, prevState, newState, boardUpdated)
            if nargin < 4
                boardUpdated = true;
            end
            this.stopMoveTimer();
            timerState = this.currentTimerState();
            if ~timerState.enabled
                this.refreshTimerLabels();
                this.updatePauseButton();
                return;
            end
            if isfield(newState, 'status') && this.isTerminalStatus(newState.status)
                timerState.running = false;
                timerState.startedAt = '';
                this.applyTimerStateToCurrentContext(timerState);
                this.refreshTimerLabels();
                this.updatePauseButton();
                return;
            end
            if this.isGamePaused()
                this.refreshTimerLabels();
                this.updateStatusBar();
                return;
            end
            if timerState.running && timerState.activeColor == newState.turn
                this.resumeTimerIfNeeded();
                this.updateStatusBar();
                return;
            end
            if isempty(this.netGame)
                if boardUpdated && strcmp(newState.status, 'active')
                    this.startTimerForColorIfEnabled(newState.turn, false);
                else
                    this.refreshTimerLabels();
                end
                return;
            end
            if this.netGame.isMyTurn() && boardUpdated && strcmp(newState.status, 'active')
                timerState.running = true;
                timerState.paused = false;
                timerState.pausedBy = '';
                timerState.activeColor = this.netGame.myColor;
                timerState.startedAt = GameState.nowISO();
                timerState.expiredColor = '';
                this.applyTimerStateToCurrentContext(timerState);
                try
                    this.netGame.save(this.netGame.lastSeenState);
                catch
                    % Keep the local display responsive even if we fail to persist
                    % the arming metadata immediately.
                end
                this.resumeTimerIfNeeded();
            end
            this.refreshTimerLabels();
        end

        function startTimerForColorIfEnabled(this, color, persistForNetwork)
            if nargin < 3
                persistForNetwork = false;
            end
            timerState = this.currentTimerState();
            if ~timerState.enabled || ~isempty(timerState.expiredColor) ...
                    || this.isTerminalStatus(this.currentGameStatus())
                this.refreshTimerLabels();
                this.updatePauseButton();
                return;
            end
            timerState.running = true;
            timerState.paused = false;
            timerState.pausedBy = '';
            timerState.activeColor = color;
            timerState.startedAt = GameState.nowISO();
            this.applyTimerStateToCurrentContext(timerState);
            if persistForNetwork && ~isempty(this.netGame)
                try
                    this.netGame.save(this.netGame.lastSeenState);
                catch
                end
            end
            this.resumeTimerIfNeeded();
        end

        function resumeTimerIfNeeded(this)
            timerState = this.currentTimerState();
            if ~timerState.enabled || ~timerState.running || ~isempty(timerState.expiredColor) ...
                    || this.isGamePaused() || this.isTerminalStatus(this.currentGameStatus())
                this.refreshTimerLabels();
                return;
            end
            this.stopMoveTimer();
            this.moveTimerObj = timer('ExecutionMode','fixedSpacing', ...
                'Period',1, 'BusyMode','drop', ...
                'TimerFcn', @(~,~) this.onTimerTick());
            start(this.moveTimerObj);
            this.refreshTimerLabels();
        end

        function stopMoveTimer(this)
            if isempty(this.moveTimerObj)
                return;
            end
            try
                stop(this.moveTimerObj);
            catch
            end
            try
                delete(this.moveTimerObj);
            catch
            end
            this.moveTimerObj = [];
        end

        % ---------------------------------------------------------------
        % Auto-poll (network mode)
        % ---------------------------------------------------------------
        % Replaces the "click Refresh" dance with a jittered background
        % poll. The tick checks the cheap hasOpponentMoved first; only
        % on true does it call the full onRefreshClicked. Jitter (5-10s)
        % prevents two clients from phase-locking onto the same share
        % point.
        %
        % The tick skips (but reschedules) if any of the following are
        % active, because blowing them away would be worse than missing
        % a cycle:
        %   - suppressInput             (mid applyToModel)
        %   - this.pendingMove          (mover is deliberating)
        %   - this.selectedFile         (a piece is picked up -- includes
        %                                mid-entry premove source pick)
        % Any one of those will be gone by the next tick at the latest.

        function startAutoPoll(this)
            if isempty(this.netGame); return; end
            this.scheduleNextPoll();
        end

        function stopAutoPoll(this)
            if isempty(this.pollTimerObj)
                return;
            end
            try
                stop(this.pollTimerObj);
            catch
            end
            try
                delete(this.pollTimerObj);
            catch
            end
            this.pollTimerObj = [];
        end

        function resetAutoPoll(this)
            % No-op if we aren't currently polling (e.g. local mode).
            % If we are, push the next tick out to a fresh interval.
            if isempty(this.netGame) || isempty(this.pollTimerObj)
                return;
            end
            this.scheduleNextPoll();
        end

        function scheduleNextPoll(this)
            % Stop first so we don't leak timers if called twice back-
            % to-back (e.g. a tick that reschedules from onCleanup
            % while onRefreshClicked also reschedules).
            this.stopAutoPoll();
            delaySec = this.POLL_MIN_SEC + rand() * this.POLL_JITTER_SEC;
            this.pollTimerObj = timer('ExecutionMode','singleShot', ...
                'StartDelay', delaySec, ...
                'TimerFcn',   @(~,~) this.onPollTick());
            start(this.pollTimerObj);
        end

        function onPollTick(this)
            % Guarantee a reschedule on every exit path (including
            % errors thrown inside onRefreshClicked). A poll loop
            % that silently dies on one bad read is worse than one
            % that keeps trying.
            rescheduler = onCleanup(@() this.scheduleNextPollIfAlive());
            try
                if ~ishandle(this.figureHandle); return; end
                if isempty(this.netGame); return; end
                if this.suppressInput; return; end
                if ~isempty(this.pendingMove); return; end
                if ~isempty(this.selectedFile); return; end

                % Cheap: just peek at moveNumber/updatedAt. Swallows
                % transient read errors internally (returns false),
                % which is exactly what we want for a background poll.
                opponentMoved = this.netGame.hasOpponentMoved();
                if ~opponentMoved
                    this.noteAutoPollWithoutMove();
                    return;
                end

                % Something changed on disk -- do the heavy refresh.
                % onRefreshClicked already calls resetAutoPoll at its
                % end; our onCleanup will then reset it again, which
                % is harmless (scheduleNextPoll always stops the old
                % timer first).
                this.onRefreshClicked(true);
            catch
                % Swallow. Cleanup reschedules, so next tick still fires.
            end
        end

        function scheduleNextPollIfAlive(this)
            if ~ishandle(this.figureHandle); return; end
            if isempty(this.netGame); return; end
            if this.isReviewMode; return; end
            this.scheduleNextPoll();
        end

        function onTimerTick(this)
            timerState = this.currentTimerState();
            if ~timerState.enabled || ~timerState.running || isempty(timerState.startedAt)
                this.refreshTimerLabels();
                return;
            end
            elapsed = GameState.elapsedSeconds(timerState.startedAt, GameState.nowISO());
            if timerState.activeColor == 'w'
                remaining = max(0, timerState.whiteRemainingSec - elapsed);
            else
                remaining = max(0, timerState.blackRemainingSec - elapsed);
            end
            if remaining <= 0
                timerState = GameState.applyElapsedToTimer(timerState, GameState.nowISO());
                if isempty(timerState.expiredColor)
                    timerState.expiredColor = timerState.activeColor;
                end
                this.applyTimerStateToCurrentContext(timerState);
                this.stopMoveTimer();
                % If the mover had a pending move queued waiting for
                % End Turn, their flag fell before they committed --
                % roll the visual move back so the board reflects
                % what is actually on disk (no move made) and the
                % pending buttons disappear.
                if ~isempty(this.pendingMove) && this.pendingMove.moverColor == timerState.expiredColor
                    this.undoPendingMove();
                end
                % Flagging also invalidates any queued premoves --
                % the game is over for this player.
                if ~isempty(this.premoveQueue)
                    this.clearPremoveQueueHighlights();
                    this.premoveQueue = {};
                end
                this.clearSelection();
                if ~isempty(this.netGame)
                    this.netGame.setCachedTimer(timerState);
                    this.netGame.setCachedStatus('timeout');
                    try
                        this.netGame.save(this.netGame.lastSeenState);
                    catch
                    end
                end
                this.updateStatusBar();
                this.notifyEnd();
                return;
            end
            this.refreshTimerLabels();
        end

        function refreshTimerLabels(this)
            if isempty(this.timerWhiteText) || ~ishandle(this.timerWhiteText)
                return;
            end
            timerState = this.currentTimerState();
            if ~timerState.enabled
                set(this.timerWhiteText, 'String', 'White  --:--', 'ForegroundColor', [0 0 0]);
                set(this.timerBlackText, 'String', 'Black  --:--', 'ForegroundColor', [0 0 0]);
                return;
            end
            whiteSec = timerState.whiteRemainingSec;
            blackSec = timerState.blackRemainingSec;
            if timerState.running && ~isempty(timerState.startedAt)
                elapsed = GameState.elapsedSeconds(timerState.startedAt, GameState.nowISO());
                if timerState.activeColor == 'w'
                    whiteSec = max(0, whiteSec - elapsed);
                else
                    blackSec = max(0, blackSec - elapsed);
                end
            end
            whiteColor = [0 0 0];
            blackColor = [0 0 0];
            if timerState.running && timerState.activeColor == 'w'
                whiteColor = [0.1 0.45 0.1];
            elseif timerState.running && timerState.activeColor == 'b'
                blackColor = [0.1 0.45 0.1];
            end
            set(this.timerWhiteText, 'String', sprintf('White  %s', this.formatClock(whiteSec)), 'ForegroundColor', whiteColor);
            set(this.timerBlackText, 'String', sprintf('Black  %s', this.formatClock(blackSec)), 'ForegroundColor', blackColor);
        end

        function s = formatClock(~, totalSec)
            totalSec = max(0, round(totalSec));
            mins = floor(totalSec / 60);
            secs = mod(totalSec, 60);
            s = sprintf('%02d:%02d', mins, secs);
        end

        function onFigureClosed(this)
            this.stopMoveTimer();
            this.stopAutoPoll();
            this.stopBotTriggerTimer();
            if ~isempty(this.stockfishBot)
                try; this.stockfishBot.quit(); catch; end
            end
            if ~isempty(this.analysisStockfishBot)
                try; this.analysisStockfishBot.quit(); catch; end
            end
            if ~isempty(this.historyFigure) && ishandle(this.historyFigure)
                try; delete(this.historyFigure); catch; end
                this.historyFigure = [];
            end
            delete(this.figureHandle);
        end

        % ---------------------------------------------------------------
        % Legacy dialogs, lightly cleaned up
        % ---------------------------------------------------------------
        % ---------------------------------------------------------------
        % Captured-piece graveyard
        % ---------------------------------------------------------------
        function createCapturedPiecePanels(this)
            topY = this.BOARD_ORIGIN_Y + this.CAPTURE_PANEL_H + this.CAPTURE_PANEL_GAP;
            botY = this.BOARD_ORIGIN_Y;

            this.capturedWhitePanel = uipanel('Parent', this.figureHandle, ...
                'Title', 'Captured by White', ...
                'FontSize', 11, ...
                'BackgroundColor', [1 1 1], ...
                'Units', 'pixels', ...
                'Position', [this.CAPTURE_PANEL_X topY ...
                             this.CAPTURE_PANEL_W this.CAPTURE_PANEL_H]);

            this.capturedBlackPanel = uipanel('Parent', this.figureHandle, ...
                'Title', 'Captured by Black', ...
                'FontSize', 11, ...
                'BackgroundColor', [1 1 1], ...
                'Units', 'pixels', ...
                'Position', [this.CAPTURE_PANEL_X botY ...
                             this.CAPTURE_PANEL_W this.CAPTURE_PANEL_H]);
        end

        function createAnalysisPanel(this)
            analysisY = this.BOARD_ORIGIN_Y + 2*this.CAPTURE_PANEL_H + ...
                        2*this.CAPTURE_PANEL_GAP;
            this.analysisPanel = uipanel('Parent', this.figureHandle, ...
                'Title', 'Stockfish Analysis', ...
                'FontSize', 11, ...
                'BackgroundColor', [1 1 1], ...
                'Units', 'pixels', ...
                'Position', [this.CAPTURE_PANEL_X analysisY ...
                             this.CAPTURE_PANEL_W this.ANALYSIS_PANEL_H]);

            this.analysisAnalyzeButton = uicontrol('Parent', this.analysisPanel, ...
                'Style','pushbutton', ...
                'String','Analyze Position', ...
                'FontSize',10, ...
                'Position',[14 244 190 28], ...
                'Enable','off', ...
                'Callback', @(~,~) this.onAnalyzeWithStockfishClicked());

            this.analysisPlayButton = uicontrol('Parent', this.analysisPanel, ...
                'Style','pushbutton', ...
                'String','Play Best Move', ...
                'FontSize',10, ...
                'Position',[14 210 190 28], ...
                'Enable','off', ...
                'Callback', @(~,~) this.onPlayStockfishBestClicked());

            this.analysisEngineButton = uicontrol('Parent', this.analysisPanel, ...
                'Style','pushbutton', ...
                'String','Change Engine...', ...
                'FontSize',10, ...
                'Position',[14 176 190 28], ...
                'Enable','off', ...
                'Callback', @(~,~) this.onChooseAnalysisEngineClicked());

            this.analysisText = uicontrol('Parent', this.analysisPanel, ...
                'Style','listbox', ...
                'FontName','Courier New', ...
                'FontSize',8, ...
                'String', {'Review Game enables Stockfish analysis.'}, ...
                'BackgroundColor',[1 1 1], ...
                'Position',[14 14 190 152], ...
                'Enable','inactive');
        end

        function onAnalyzeWithStockfishClicked(this)
            if ~this.isReviewMode
                return;
            end
            if this.analysisBusy
                this.setAnalysisLines({'Stockfish is already analyzing.', ...
                    'Wait for the current search to finish.'});
                return;
            end

            % Always bind analysis to the board that is currently shown.
            % This matters in review mode because the user may jump to an
            % old ply, play a throwaway variation, then analyze again.
            fen = this.currentFenForAnalysis();
            this.analysisBusy = true;
            this.analysisBestMove = [];
            this.analysisBestFen = '';
            this.setAnalysisLines({'Stockfish thinking...', ...
                ['FEN: ' fen], ...
                'Running a fresh full-strength analysis for this board.'});
            this.updateActionButtons();
            drawnow;

            try
                % Post-game analysis is intentionally stateless: each click
                % creates a clean UCI search session. This avoids the failure
                % mode where stale UCI output from the previous analysis makes
                % the next click appear blank or leaves the buttons disabled.
                this.restartAnalysisStockfishBot();
                bot = this.ensureAnalysisStockfishBot();
                mv = bot.bestMoveFromFen(fen, []);
                this.restartAnalysisStockfishBot();

                this.analysisBestMove = mv;
                this.analysisBestFen = fen;
                this.analysisBusy = false;
                this.showAnalysisResult(mv, fen);
                this.updateActionButtons();
            catch err
                this.restartAnalysisStockfishBot();
                this.analysisBestMove = [];
                this.analysisBestFen = '';
                this.analysisBusy = false;
                this.setAnalysisLines({'Stockfish analysis failed:', err.message, ...
                    'If this game was started against Stockfish, the same engine path is reused automatically.', ...
                    'Otherwise choose Engine... and try again.'});
                this.updateActionButtons();
                try
                    errordlg(sprintf('Stockfish analysis failed:\n%s', err.message), ...
                        'Stockfish analysis error', 'modal');
                catch
                end
            end
        end

        function onPlayStockfishBestClicked(this)
            if ~this.isReviewMode || this.analysisBusy
                return;
            end
            if isempty(this.analysisBestMove) || ~isstruct(this.analysisBestMove) || isempty(this.analysisBestMove.uci)
                this.onAnalyzeWithStockfishClicked();
            end
            mv = this.analysisBestMove;
            if isempty(mv) || ~isstruct(mv) || isempty(mv.uci)
                return;
            end
            currentFen = this.currentFenForAnalysis();
            if ~isempty(this.analysisBestFen) && ~strcmp(char(this.analysisBestFen), char(currentFen))
                this.analysisBestMove = [];
                this.analysisBestFen = '';
                this.setAnalysisLines({'The board changed after the last analysis.', ...
                    'Click Analyze Position again for this game state.'});
                this.updateActionButtons();
                return;
            end
            try
                this.applyAnalysisMove(mv);
                this.analysisBestMove = [];
                this.analysisBestFen = '';
                this.setAnalysisLines({'Best move played on board.', ...
                    'Analyze again to continue the variation.'});
            catch err
                this.analysisBestMove = [];
                this.analysisBestFen = '';
                errordlg(sprintf('Could not play Stockfish best move:\n%s', err.message), ...
                    'Analysis move failed', 'modal');
            end
            this.updateActionButtons();
        end

        function onChooseAnalysisEngineClicked(this)
            if ispc
                filt = {'stockfish*.exe;*.exe', 'Stockfish executable (*.exe)'; '*.*', 'All files'};
            else
                filt = {'stockfish*;*', 'Stockfish executable'; '*.*', 'All files'};
            end
            [f, pth] = uigetfile(filt, 'Select Stockfish executable for analysis');
            if isequal(f, 0)
                return;
            end
            newPath = fullfile(pth, f);
            this.analysisEnginePath = newPath;
            if ~isempty(this.analysisStockfishBot)
                try; this.analysisStockfishBot.quit(); catch; end
                this.analysisStockfishBot = [];
            end
            this.analysisBestMove = [];
            this.analysisBestFen = '';
            this.setAnalysisLines({'Analysis engine selected:', newPath, ...
                'Click Analyze Position.'});
            this.updateActionButtons();
        end

        function bot = ensureAnalysisStockfishBot(this)
            this.rememberAnalysisEnginePathFromGame();
            if isempty(this.analysisEnginePath)
                this.onChooseAnalysisEngineClicked();
            end
            if isempty(this.analysisEnginePath)
                error('No Stockfish executable has been selected for analysis.');
            end

            if ~isempty(this.analysisStockfishBot)
                try
                    if this.analysisStockfishBot.isStarted && ~isempty(this.analysisStockfishBot.process) ...
                            && this.analysisStockfishBot.process.isAlive()
                        bot = this.analysisStockfishBot;
                        return;
                    end
                catch
                    try; this.analysisStockfishBot.quit(); catch; end
                    this.analysisStockfishBot = [];
                end
            end

            baseOptions = StockfishBot.defaultOptions();
            if ~isempty(this.stockfishBot) && isprop(this.stockfishBot, 'options')
                baseOptions = this.stockfishBot.options;
            end
            analysisOptions = StockfishBot.fullStrengthAnalysisOptions(baseOptions);
            bot = StockfishBot(this.analysisEnginePath, analysisOptions);
            bot.start();
            this.analysisStockfishBot = bot;
        end

        function rememberAnalysisEnginePathFromGame(this)
            % In games started through "Play against Stockfish", reuse the
            % exact executable path selected at startup for post-game
            % analysis. The user should not need to pick the same engine a
            % second time after clicking Review Game.
            if isempty(this.analysisEnginePath) && ~isempty(this.stockfishBot) ...
                    && isprop(this.stockfishBot, 'enginePath')
                try
                    this.analysisEnginePath = char(this.stockfishBot.enginePath);
                catch
                end
            end
        end

        function restartAnalysisStockfishBot(this)
            if ~isempty(this.analysisStockfishBot)
                try; this.analysisStockfishBot.quit(); catch; end
            end
            this.analysisStockfishBot = [];
        end

        function applyAnalysisMove(this, mv)
            if isempty(mv) || ~isstruct(mv) || isempty(mv.uci)
                error('No Stockfish best move is available.');
            end
            if isempty(mv.srcFile) || isempty(mv.srcRank) || isempty(mv.dstFile) || isempty(mv.dstRank)
                error('Stockfish returned an invalid move: %s', mv.uci);
            end
            coords = [mv.srcFile mv.srcRank mv.dstFile mv.dstRank];
            if any(coords < 1) || any(coords > 8)
                error('Stockfish returned an invalid move: %s', mv.uci);
            end
            srcBtn = this.chessBoardModel.chessBoardBoxes(mv.srcFile, mv.srcRank).button;
            srcPiece = srcBtn.UserData;
            if isempty(srcPiece) || ischar(srcPiece)
                error('No piece exists on Stockfish source square %s.', mv.uci(1:2));
            end
            validMoves = srcPiece.ValidMoves();
            isLegal = ~isempty(validMoves) && any(validMoves(:,1)==mv.dstFile & validMoves(:,2)==mv.dstRank);
            if ~isLegal
                error('Stockfish returned %s, but that move is not legal in the current MATLAB board state.', mv.uci);
            end
            this.performMove(mv.srcFile, mv.srcRank, mv.dstFile, mv.dstRank, mv.promotion);
        end

        function showAnalysisResult(this, mv, fen)
            lines = {};
            lines{end+1} = ['FEN: ' fen]; %#ok<AGROW>
            if isempty(mv) || ~isstruct(mv) || isempty(mv.uci)
                lines{end+1} = 'No legal best move returned.'; %#ok<AGROW>
                lines{end+1} = 'The position may already be terminal.'; %#ok<AGROW>
                this.setAnalysisLines(lines);
                return;
            end

            lines{end+1} = ['Best: ' this.describeUciMove(mv.uci)]; %#ok<AGROW>
            if isfield(mv, 'pvs') && ~isempty(mv.pvs)
                lines{end+1} = 'Top Stockfish lines:'; %#ok<AGROW>
                pvs = mv.pvs;
                for k = 1:min(3, numel(pvs))
                    lines{end+1} = sprintf('%d) %-7s  %s  d%s', ...
                        pvs(k).multipv, this.formatScore(pvs(k)), ...
                        this.describeUciMove(pvs(k).firstMove), ...
                        this.formatDepth(pvs(k).depth)); %#ok<AGROW>
                    if isfield(pvs(k), 'line') && ~isempty(pvs(k).line)
                        lines{end+1} = ['   pv ' char(pvs(k).line)]; %#ok<AGROW>
                    end
                end
            end
            this.setAnalysisLines(lines);
        end

        function setAnalysisLines(this, lines)
            if isempty(this.analysisText) || ~ishandle(this.analysisText)
                return;
            end
            if ischar(lines) || isstring(lines)
                lines = cellstr(lines);
            end
            if isempty(lines)
                lines = {''};
            end
            set(this.analysisText, 'String', lines, 'Value', 1);
        end

        function clearAnalysisBestMove(this, msg)
            this.analysisBestMove = [];
            this.analysisBestFen = '';
            if nargin >= 2 && ~isempty(msg)
                this.setAnalysisLines(msg);
            end
        end

        function fen = currentFenForAnalysis(this)
            state = GameState.fromModel(this.chessBoardModel);
            boardChars = char(state.board);
            side = this.gameController.whoPlays();
            rights = this.castlingRightsFromBoard(boardChars, state.moved);
            ep = this.enPassantFenSquare(this.chessBoardModel.enPassantInfo);
            halfmove = 0;
            fullmove = max(1, floor((double(this.gameController.round) + 1) / 2));
            fen = sprintf('%s %c %s %s %d %d', ...
                this.boardCharsToFenPlacement(boardChars), side, rights, ep, halfmove, fullmove);
        end

        function placement = boardCharsToFenPlacement(~, boardChars)
            ranks = cell(8,1);
            for rank = 8:-1:1
                row = boardChars(rank, :);
                out = '';
                emptyCount = 0;
                for file = 1:8
                    c = row(file);
                    if c == '.' || c == 0
                        emptyCount = emptyCount + 1;
                    else
                        if emptyCount > 0
                            out = [out sprintf('%d', emptyCount)]; %#ok<AGROW>
                            emptyCount = 0;
                        end
                        out = [out c]; %#ok<AGROW>
                    end
                end
                if emptyCount > 0
                    out = [out sprintf('%d', emptyCount)]; %#ok<AGROW>
                end
                ranks{9-rank} = out;
            end
            placement = strjoin(ranks, '/');
        end

        function s = enPassantFenSquare(~, enPassantInfo)
            s = '-';
            if isempty(enPassantInfo) || ~isstruct(enPassantInfo) || ~isfield(enPassantInfo, 'target')
                return;
            end
            target = enPassantInfo.target;
            if isempty(target) || ~isnumeric(target)
                return;
            end
            target = double(target(:).');
            if numel(target) ~= 2
                return;
            end
            file = target(1);
            rank = target(2);
            if file < 1 || file > 8 || rank < 1 || rank > 8
                return;
            end
            s = sprintf('%c%d', char('a' + file - 1), rank);
        end

        function desc = describeUciMove(this, uci)
            uci = char(uci);
            if numel(uci) < 4
                desc = uci;
                return;
            end
            srcFile = double(uci(1)) - double('a') + 1;
            srcRank = str2double(uci(2));
            dstFile = double(uci(3)) - double('a') + 1;
            dstRank = str2double(uci(4));
            pieceLabel = '';
            try
                btn = this.chessBoardModel.chessBoardBoxes(srcFile, srcRank).button;
                piece = btn.UserData;
                if ~isempty(piece) && ~ischar(piece)
                    pieceLabel = piece.id;
                    if pieceLabel == 'P'
                        pieceLabel = '';
                    end
                end
            catch
            end
            promo = '';
            if numel(uci) >= 5
                promo = ['=' upper(uci(5))];
            end
            desc = sprintf('%s%s-%s%s', pieceLabel, uci(1:2), uci(3:4), promo);
        end

        function s = formatScore(~, pv)
            s = '';
            if ~isfield(pv, 'scoreType') || isempty(pv.scoreType) || ~isfield(pv, 'scoreValue') || isnan(pv.scoreValue)
                return;
            end
            if strcmp(pv.scoreType, 'mate')
                s = sprintf('M%+d', pv.scoreValue);
            else
                s = sprintf('%+.2f', double(pv.scoreValue)/100);
            end
        end

        function s = formatDepth(~, depth)
            if isempty(depth) || isnan(depth)
                s = '?';
            else
                s = sprintf('%d', round(double(depth)));
            end
        end

        function updateCapturedPiecesPanel(this)
            if isempty(this.figureHandle) || ~ishandle(this.figureHandle)
                return;
            end
            if isempty(this.capturedWhitePanel) || ~ishandle(this.capturedWhitePanel) || ...
               isempty(this.capturedBlackPanel) || ~ishandle(this.capturedBlackPanel)
                return;
            end

            history = this.historyForCapturedPieces();
            [capturedByWhite, capturedByBlack] = this.capturedPiecesFromHistory(history);

            % Standard material ordering: Q, R, B, N, P. The labels are
            % from the capturer's perspective, so "Captured by White" shows
            % black pieces that White has taken, and vice versa.
            capturedByWhite = this.sortCapturedCodes(capturedByWhite);
            capturedByBlack = this.sortCapturedCodes(capturedByBlack);

            this.renderCapturedPieceIcons(this.capturedWhitePanel, capturedByWhite, 'w');
            this.renderCapturedPieceIcons(this.capturedBlackPanel, capturedByBlack, 'b');
        end

        function history = historyForCapturedPieces(this)
            history = {};
            if isempty(this.netGame)
                history = this.localMoveHistory;
            else
                state = this.netGame.lastSeenState;
                if isstruct(state) && isfield(state, 'history')
                    history = state.history;
                end
            end

            if isempty(history)
                history = {};
                return;
            end
            if ~iscell(history)
                if isstruct(history)
                    history = arrayfun(@(x) x, history, 'UniformOutput', false);
                else
                    history = {};
                end
            end
            history = history(:);

            % While reviewing a past board snapshot, the graveyard should
            % match the position being viewed rather than the live position.
            if ~isempty(this.rewindIndex)
                n = max(0, min(double(this.rewindIndex), numel(history)));
                history = history(1:n);
            end
        end

        function [capturedByWhite, capturedByBlack] = capturedPiecesFromHistory(this, history)
            capturedByWhite = '';
            capturedByBlack = '';
            if isempty(history)
                return;
            end

            initialBoard = this.initialBoardCell();
            for k = 1:numel(history)
                mv = history{k};
                if ~isstruct(mv)
                    continue;
                end

                capturedCode = '';
                if isfield(mv, 'capture') && this.truthy(mv.capture)
                    % Newer history rows store the captured piece directly.
                    % Older rows can still be decoded from the previous
                    % boardAfter snapshot, with the standard starting board
                    % as the fallback for the first move.
                    if isfield(mv, 'capturedPiece') && ~isempty(mv.capturedPiece)
                        capturedCode = char(mv.capturedPiece);
                        capturedCode = capturedCode(1);
                    else
                        if k == 1
                            boardBefore = initialBoard;
                        else
                            prev = history{k-1};
                            if isstruct(prev) && isfield(prev, 'boardAfter') && ~isempty(prev.boardAfter)
                                boardBefore = prev.boardAfter;
                            else
                                boardBefore = initialBoard;
                            end
                        end

                        if isfield(mv, 'enPassant') && this.truthy(mv.enPassant) && ...
                                isfield(mv, 'from') && isfield(mv, 'to')
                            from = double(mv.from(:).');  % stored as [rank file]
                            to   = double(mv.to(:).');    % stored as [rank file]
                            if numel(from) == 2 && numel(to) == 2
                                capturedCode = this.boardCharAt(boardBefore, from(1), to(2));
                            end
                        elseif isfield(mv, 'to')
                            to = double(mv.to(:).');      % stored as [rank file]
                            if numel(to) == 2
                                capturedCode = this.boardCharAt(boardBefore, to(1), to(2));
                            end
                        end
                    end

                    if ~isempty(capturedCode) && capturedCode ~= '.'
                        if capturedCode == lower(capturedCode)
                            capturedByWhite(end+1) = capturedCode; %#ok<AGROW>
                        else
                            capturedByBlack(end+1) = capturedCode; %#ok<AGROW>
                        end
                    end
                end
            end
        end

        function renderCapturedPieceIcons(this, panelHandle, pieceCodes, sideKey)
            if nargin < 4
                sideKey = '';
            end
            if strcmp(sideKey, 'w')
                this.clearCapturedIconHandles('w');
            else
                this.clearCapturedIconHandles('b');
            end
            if isempty(pieceCodes)
                return;
            end

            iconHandles = [];
            x0 = 14;
            y0 = this.CAPTURE_PANEL_H - 52;
            step = this.CAPTURE_ICON_PX + this.CAPTURE_ICON_GAP;

            for n = 1:numel(pieceCodes)
                col = mod(n-1, this.CAPTURE_GRID_COLS);
                row = floor((n-1) / this.CAPTURE_GRID_COLS);
                x = x0 + col * step;
                y = y0 - row * step;
                if y < 12
                    % The panel can hold more pieces than a legal chess game
                    % needs, but guard anyway if custom positions are used.
                    break;
                end

                cdata = this.smallPieceCData(pieceCodes(n));
                h = uicontrol('Parent', panelHandle, ...
                    'Style', 'pushbutton', ...
                    'String', '', ...
                    'Enable', 'inactive', ...
                    'CData', cdata, ...
                    'BackgroundColor', [1 1 1], ...
                    'Position', [x y this.CAPTURE_ICON_PX this.CAPTURE_ICON_PX]);
                iconHandles = [iconHandles h]; %#ok<AGROW>
            end

            if strcmp(sideKey, 'w')
                this.capturedWhiteIcons = iconHandles;
            else
                this.capturedBlackIcons = iconHandles;
            end
        end

        function clearCapturedIconHandles(this, sideKey)
            if strcmp(sideKey, 'w')
                handles = this.capturedWhiteIcons;
                this.capturedWhiteIcons = [];
            else
                handles = this.capturedBlackIcons;
                this.capturedBlackIcons = [];
            end
            for k = 1:numel(handles)
                try
                    if ishandle(handles(k))
                        delete(handles(k));
                    end
                catch
                end
            end
        end

        function sortedCodes = sortCapturedCodes(~, pieceCodes)
            sortedCodes = pieceCodes;
            if isempty(pieceCodes)
                return;
            end
            order = 'QRBNP';
            weights = zeros(1, numel(pieceCodes));
            for k = 1:numel(pieceCodes)
                idx = find(order == upper(pieceCodes(k)), 1);
                if isempty(idx)
                    weights(k) = numel(order) + 1;
                else
                    weights(k) = idx;
                end
            end
            [~, idx] = sort(weights, 'ascend');
            sortedCodes = pieceCodes(idx);
        end

        function img = smallPieceCData(this, pieceCode)
            if isempty(pieceCode) || pieceCode == '.'
                img = nan(this.CAPTURE_ICON_PX, this.CAPTURE_ICON_PX, 3);
                return;
            end
            if pieceCode == lower(pieceCode)
                colorLetter = 'B';
            else
                colorLetter = 'W';
            end
            imgName = sprintf('resources/%s%s.png', upper(pieceCode), colorLetter);
            img = ChessBoardGUI.createRGB(imgName);
            img = this.resizeCDataNearest(img, this.CAPTURE_ICON_PX, this.CAPTURE_ICON_PX);
        end

        function out = resizeCDataNearest(~, img, outH, outW)
            if isempty(img)
                out = nan(outH, outW, 3);
                return;
            end
            inH = size(img, 1);
            inW = size(img, 2);
            r = max(1, min(inH, round(linspace(1, inH, outH))));
            c = max(1, min(inW, round(linspace(1, inW, outW))));
            out = img(r, c, :);
        end

        function code = pieceObjToBoardCode(~, piece)
            code = '';
            if isempty(piece) || ischar(piece)
                return;
            end
            if ~isprop(piece, 'id') || ~isprop(piece, 'color')
                return;
            end
            code = piece.id;
            if piece.color == 'b'
                code = lower(code);
            end
        end

        function c = boardCharAt(~, board, rank, file)
            c = '';
            if isempty(board) || isempty(rank) || isempty(file)
                return;
            end
            rank = double(rank);
            file = double(file);
            if rank < 1 || rank > 8 || file < 1 || file > 8
                return;
            end
            try
                if iscell(board)
                    row = char(board{rank});
                    c = row(file);
                elseif isstring(board)
                    row = char(board(rank));
                    c = row(file);
                else
                    c = board(rank, file);
                end
            catch
                c = '';
            end
        end

        function board = initialBoardCell(~)
            board = {
                'RNBQKBNR'
                'PPPPPPPP'
                '........'
                '........'
                '........'
                '........'
                'pppppppp'
                'rnbqkbnr'
            };
        end

        function tf = truthy(~, x)
            tf = false;
            if isempty(x)
                return;
            elseif islogical(x) || isnumeric(x)
                tf = logical(x(1));
            elseif ischar(x)
                tf = strcmpi(x, 'true') || strcmp(x, '1');
            elseif isstring(x)
                tf = strcmpi(char(x), 'true') || strcmp(char(x), '1');
            end
        end

        function appendLocalHistoryMove(this, p, finalPiece, checkState)
            stateAfter = GameState.fromModel(this.chessBoardModel);

            finalPieceId = p.moverPieceIdOriginal;
            finalColor   = p.moverColor;
            if ~isempty(finalPiece) && ~ischar(finalPiece)
                finalPieceId = finalPiece.id;
                finalColor   = finalPiece.color;
            end
            wasPromotion = (p.moverPieceIdOriginal == 'P') && (finalPieceId ~= 'P');

            mv = struct( ...
                'moveNumber', p.prevMoveNumber, ...
                'from',      [p.srcRank p.srcFile], ...
                'to',        [p.dstRank p.dstFile], ...
                'piece',     finalPieceId, ...
                'color',     finalColor, ...
                'capture',   p.wasCapture, ...
                'capturedPiece', p.capturedPieceCode, ...
                'promotion', wasPromotion, ...
                'castle',    p.castleInfo.isCastle, ...
                'castleSide', p.castleInfo.side, ...
                'enPassant', p.enPassantInfo.isEnPassant, ...
                'check',     strcmp(checkState, 'check'), ...
                'checkmate', strcmp(checkState, 'checkmate'), ...
                'stalemate', strcmp(checkState, 'stalemate'), ...
                'draw',      this.isDrawStatus(checkState), ...
                'drawReason', this.drawReasonForStatus(checkState), ...
                'drawRepetition', strcmp(checkState, 'draw_repetition'), ...
                'at',        GameState.nowISO(), ...
                'boardAfter', {stateAfter.board}, ...
                'movedAfter', stateAfter.moved, ...
                'turnAfter', this.gameController.whoPlays());
            mv.enPassantInfoAfter = this.chessBoardModel.enPassantInfo;

            this.localMoveHistory = [this.localMoveHistory; {mv}];
        end

        function status = statusAfterMoveForOpponent(this, opponentColor)
            status = '';
            if this.gameController.isKingInCheck(opponentColor)
                if ~this.gameController.hasAnyLegalMove(opponentColor)
                    status = 'checkmate';
                else
                    status = 'check';
                end
            elseif ~this.gameController.hasAnyLegalMove(opponentColor)
                status = 'stalemate';
            end
        end

        function state = currentLocalFullState(this)
            state = GameState.fromModel(this.chessBoardModel);
            state.turn = this.gameController.whoPlays();
            state.moveNumber = this.gameController.round;
            state.history = this.localMoveHistory;
            state.status = this.localGameStatus;
            state.enPassantInfo = this.chessBoardModel.enPassantInfo;
            state.timer = this.currentTimerState();
        end

        function state = currentHistoryState(this)
            if ~isempty(this.netGame)
                state = this.netGame.lastSeenState;
                return;
            end
            state = this.currentLocalFullState();
            if isempty(this.localMoveHistory)
                state.lastMove = [];
                return;
            end
            lastMove = this.localMoveHistory{end};
            state.lastMove = lastMove;
            if isstruct(lastMove)
                if isfield(lastMove, 'boardAfter') && ~isempty(lastMove.boardAfter)
                    state.board = lastMove.boardAfter;
                end
                if isfield(lastMove, 'movedAfter') && ~isempty(lastMove.movedAfter)
                    state.moved = lastMove.movedAfter;
                end
                if isfield(lastMove, 'turnAfter') && ~isempty(lastMove.turnAfter)
                    state.turn = lastMove.turnAfter;
                    if isstring(state.turn); state.turn = char(state.turn); end
                    state.turn = state.turn(1);
                end
                if isfield(lastMove, 'enPassantInfoAfter')
                    state.enPassantInfo = lastMove.enPassantInfoAfter;
                end
            end
            state.moveNumber = numel(this.localMoveHistory) + 1;
            state.history = this.localMoveHistory;
            state.status = this.localGameStatus;
            state.timer = this.currentTimerState();
        end

        function status = currentGameStatus(this)
            if isempty(this.netGame)
                status = this.localGameStatus;
            else
                if isfield(this.netGame.lastSeenState, 'status') && ~isempty(this.netGame.lastSeenState.status)
                    status = this.netGame.lastSeenState.status;
                else
                    status = 'active';
                end
            end
            if isstring(status); status = char(status); end
        end

        function tf = isTerminalStatus(this, status) %#ok<INUSL>
            if nargin < 2 || isempty(status)
                tf = false;
                return;
            end
            if isstring(status); status = char(status); end
            tf = any(strcmp(status, {'checkmate','timeout','stalemate','draw','draw_repetition','repetition'}));
        end

        function tf = isDrawStatus(this, status) %#ok<INUSL>
            if nargin < 2 || isempty(status)
                tf = false;
                return;
            end
            if isstring(status); status = char(status); end
            tf = any(strcmp(status, {'stalemate','draw','draw_repetition','repetition'}));
        end

        function reason = drawReasonForStatus(this, status) %#ok<INUSL>
            reason = '';
            if nargin < 2 || isempty(status)
                return;
            end
            if isstring(status); status = char(status); end
            switch status
                case 'stalemate'
                    reason = 'stalemate';
                case {'draw_repetition','repetition'}
                    reason = 'threefold repetition';
                case 'draw'
                    reason = 'draw';
            end
        end

        function tf = isThreefoldRepetition(this, state)
            tf = false;
            if nargin < 2 || isempty(state) || ~isstruct(state)
                return;
            end
            sig = this.positionSignature(state.board, state.turn, state.moved, state.enPassantInfo);
            tf = this.repetitionCountForSignature(state, sig) >= 3;
        end

        function count = repetitionCountForSignature(this, state, signature)
            count = 0;
            if nargin < 3 || isempty(signature)
                return;
            end

            initialSig = this.positionSignature(this.initialBoardCell(), 'w', false(8,8), []);
            if strcmp(signature, initialSig)
                count = count + 1;
            end

            if ~isfield(state, 'history') || isempty(state.history)
                return;
            end
            history = state.history;
            if ~iscell(history)
                if isstruct(history)
                    history = arrayfun(@(x) x, history, 'UniformOutput', false);
                else
                    return;
                end
            end

            for k = 1:numel(history)
                mv = history{k};
                if ~isstruct(mv) || ~isfield(mv, 'boardAfter') || isempty(mv.boardAfter)
                    continue;
                end

                movedAfter = false(8,8);
                if isfield(mv, 'movedAfter') && ~isempty(mv.movedAfter)
                    movedAfter = logical(mv.movedAfter);
                end

                turnAfter = '';
                if isfield(mv, 'turnAfter') && ~isempty(mv.turnAfter)
                    turnAfter = mv.turnAfter;
                    if isstring(turnAfter); turnAfter = char(turnAfter); end
                    turnAfter = turnAfter(1);
                elseif isfield(mv, 'color') && ~isempty(mv.color)
                    c = mv.color;
                    if isstring(c); c = char(c); end
                    turnAfter = this.oppositeColor(c(1));
                else
                    % Fallback for very old history rows.
                    if mod(k, 2) == 0; turnAfter = 'w'; else; turnAfter = 'b'; end
                end

                epiAfter = [];
                if isfield(mv, 'enPassantInfoAfter')
                    epiAfter = mv.enPassantInfoAfter;
                end

                sigK = this.positionSignature(mv.boardAfter, turnAfter, movedAfter, epiAfter);
                if strcmp(signature, sigK)
                    count = count + 1;
                end
            end
        end

        function signature = positionSignature(this, board, turnColor, moved, enPassantInfo)
            if isempty(board)
                boardChars = repmat('.', 8, 8);
            elseif iscell(board)
                boardChars = char(board);
            elseif isstring(board)
                boardChars = char(cellstr(board));
            else
                boardChars = char(board);
            end
            if size(boardChars,1) ~= 8 || size(boardChars,2) ~= 8
                tmp = repmat('.', 8, 8);
                rr = min(8, size(boardChars,1));
                cc = min(8, size(boardChars,2));
                tmp(1:rr,1:cc) = boardChars(1:rr,1:cc);
                boardChars = tmp;
            end
            if nargin < 4 || isempty(moved)
                moved = false(8,8);
            else
                moved = logical(moved);
                if size(moved,1) ~= 8 || size(moved,2) ~= 8
                    tmp = false(8,8);
                    rr = min(8, size(moved,1));
                    cc = min(8, size(moved,2));
                    tmp(1:rr,1:cc) = moved(1:rr,1:cc);
                    moved = tmp;
                end
            end
            if isempty(turnColor)
                turnColor = '?';
            elseif isstring(turnColor)
                turnColor = char(turnColor);
            end
            rights = this.castlingRightsFromBoard(boardChars, moved);
            ep = this.enPassantTargetString(enPassantInfo);
            signature = sprintf('%s|%c|%s|%s', boardChars(:).', turnColor(1), rights, ep);
        end

        function rights = castlingRightsFromBoard(~, boardChars, moved)
            rights = '';
            if boardChars(1,5) == 'K' && ~moved(1,5)
                if boardChars(1,8) == 'R' && ~moved(1,8)
                    rights = [rights 'K']; %#ok<AGROW>
                end
                if boardChars(1,1) == 'R' && ~moved(1,1)
                    rights = [rights 'Q']; %#ok<AGROW>
                end
            end
            if boardChars(8,5) == 'k' && ~moved(8,5)
                if boardChars(8,8) == 'r' && ~moved(8,8)
                    rights = [rights 'k']; %#ok<AGROW>
                end
                if boardChars(8,1) == 'r' && ~moved(8,1)
                    rights = [rights 'q']; %#ok<AGROW>
                end
            end
            if isempty(rights)
                rights = '-';
            end
        end

        function s = enPassantTargetString(~, enPassantInfo)
            s = '-';
            if isempty(enPassantInfo) || ~isstruct(enPassantInfo) || ~isfield(enPassantInfo, 'target')
                return;
            end
            target = enPassantInfo.target;
            if isempty(target) || ~isnumeric(target)
                return;
            end
            target = double(target(:).');
            if numel(target) ~= 2
                return;
            end
            s = sprintf('%d,%d', target(1), target(2));
        end

        function state = markStateAsDraw(this, state, status)
            state.status = status;
            if isfield(state, 'lastMove') && isstruct(state.lastMove)
                state.lastMove.check = false;
                state.lastMove.checkmate = false;
                state.lastMove.stalemate = strcmp(status, 'stalemate');
                state.lastMove.draw = true;
                state.lastMove.drawReason = this.drawReasonForStatus(status);
                state.lastMove.drawRepetition = strcmp(status, 'draw_repetition') || strcmp(status, 'repetition');
                if isfield(state, 'history') && ~isempty(state.history)
                    state.history{end} = state.lastMove;
                end
            end
        end

        function markLastLocalMoveAsDraw(this, status)
            if isempty(this.localMoveHistory)
                return;
            end
            mv = this.localMoveHistory{end};
            mv.check = false;
            mv.checkmate = false;
            mv.stalemate = strcmp(status, 'stalemate');
            mv.draw = true;
            mv.drawReason = this.drawReasonForStatus(status);
            mv.drawRepetition = strcmp(status, 'draw_repetition') || strcmp(status, 'repetition');
            this.localMoveHistory{end} = mv;
        end

        function tf = didStateEnterTerminal(this, prevState, newState, boardUpdated)
            if nargin < 4; boardUpdated = true; end
            tf = false;
            if nargin < 3 || isempty(newState) || ~isfield(newState, 'status')
                return;
            end
            if this.didStateEnterTimeout(prevState, newState)
                tf = true;
                return;
            end
            if ~boardUpdated || ~this.isTerminalStatus(newState.status)
                return;
            end
            if strcmp(newState.status, 'timeout')
                return;
            end
            prevStatus = '';
            if nargin >= 2 && ~isempty(prevState) && isfield(prevState, 'status') && ~isempty(prevState.status)
                prevStatus = prevState.status;
            end
            tf = ~strcmp(prevStatus, newState.status);
        end

        function notifyForTerminalState(this, state)
            if isempty(state) || ~isstruct(state) || ~isfield(state, 'status')
                return;
            end
            if this.isDrawStatus(state.status)
                this.notifyDraw(state.status);
            elseif strcmp(state.status, 'checkmate') || strcmp(state.status, 'timeout')
                this.notifyEnd();
            end
        end

        function tf = didStateEnterTimeout(this, prevState, newState) %#ok<INUSL>
            tf = false;
            if nargin < 3 || isempty(newState) || ~isfield(newState, 'status')
                return;
            end
            if ~strcmp(newState.status, 'timeout')
                return;
            end

            prevWasTimeout = false;
            if nargin >= 2 && ~isempty(prevState) && isfield(prevState, 'status')
                prevWasTimeout = strcmp(prevState.status, 'timeout');
            end

            prevExpired = '';
            if nargin >= 2 && ~isempty(prevState) && isfield(prevState, 'timer')
                prevTimer = GameState.normalizeTimerState(prevState.timer);
                prevExpired = prevTimer.expiredColor;
            end

            newExpired = '';
            if isfield(newState, 'timer')
                newTimer = GameState.normalizeTimerState(newState.timer);
                newExpired = newTimer.expiredColor;
            end

            tf = ~prevWasTimeout || ~strcmp(prevExpired, newExpired);
        end


        % ---------------------------------------------------------------
        % Stockfish bot integration
        % ---------------------------------------------------------------
        function tf = isStockfishGame(this)
            tf = ~isempty(this.stockfishBot);
        end

        function scheduleStockfishMoveIfNeeded(this)
            if ~this.shouldStockfishMoveNow(); return; end

            % Run the engine move after the current GUI callback returns.
            % This avoids nesting the engine search inside the human move
            % callback, which could leave the board looking/acting locked
            % until MATLAB unwinds the whole call stack.
            this.stopBotTriggerTimer();
            try
                this.botTriggerTimer = timer('ExecutionMode','singleShot', ...
                    'StartDelay',0.05, ...
                    'TimerFcn', @(~,~) this.onStockfishTriggerTimer());
                start(this.botTriggerTimer);
            catch
                % Timer creation can fail in unusual MATLAB states. Fall
                % back to a direct call so Stockfish games remain playable.
                this.botTriggerTimer = [];
                this.maybeTriggerStockfishMove();
            end
        end

        function onStockfishTriggerTimer(this)
            this.stopBotTriggerTimer();
            this.maybeTriggerStockfishMove();
        end

        function stopBotTriggerTimer(this)
            if isempty(this.botTriggerTimer)
                return;
            end
            try
                stop(this.botTriggerTimer);
            catch
            end
            try
                delete(this.botTriggerTimer);
            catch
            end
            this.botTriggerTimer = [];
        end

        function tf = shouldStockfishMoveNow(this)
            tf = this.isStockfishGame() ...
                && ~this.isReviewMode ...
                && ~this.botThinking ...
                && isempty(this.netGame) ...
                && isempty(this.pendingMove) ...
                && ~this.isTerminalStatus(this.currentGameStatus()) ...
                && ~this.isClockExpired() ...
                && ~this.isGamePaused() ...
                && this.gameController.whoPlays() ~= this.playerColor;
        end

        function maybeTriggerStockfishMove(this)
            if ~this.shouldStockfishMoveNow(); return; end

            this.botThinking = true;
            cleanupObj = onCleanup(@() this.cleanupStockfishThinkingFlag()); %#ok<NASGU>
            this.clearSelection();
            this.updateStatusBar();
            this.updateActionButtons();
            drawnow;

            try
                mv = this.stockfishBot.bestMove(this.localMoveHistory, this.currentTimerState());
                if isempty(mv) || ~isstruct(mv) || isempty(mv.uci)
                    error('Stockfish did not return a playable bestmove.');
                end
                this.applyStockfishMove(mv);
            catch err
                this.notifyStockfishError(err);
            end
        end

        function cleanupStockfishThinkingFlag(this)
            try
                this.botThinking = false;
                if ishandle(this.figureHandle)
                    this.updateStatusBar();
                    this.updateActionButtons();
                end
            catch
            end
        end

        function applyStockfishMove(this, mv)
            srcFile = mv.srcFile;
            srcRank = mv.srcRank;
            dstFile = mv.dstFile;
            dstRank = mv.dstRank;
            if isempty(srcFile) || isempty(srcRank) || isempty(dstFile) || isempty(dstRank)
                error('Stockfish returned an invalid UCI move.');
            end
            if any([srcFile srcRank dstFile dstRank] < 1) || any([srcFile srcRank dstFile dstRank] > 8)
                error('Stockfish returned an out-of-board UCI move: %s', mv.uci);
            end

            srcBtn = this.chessBoardModel.chessBoardBoxes(srcFile, srcRank).button;
            srcPiece = srcBtn.UserData;
            if isempty(srcPiece) || ischar(srcPiece)
                error('Stockfish returned %s, but there is no piece on the source square.', mv.uci);
            end
            if srcPiece.color == this.playerColor
                error('Stockfish returned %s, which moves the human player''s piece.', mv.uci);
            end

            validMoves = srcPiece.ValidMoves();
            isLegal = ~isempty(validMoves) && any(validMoves(:,1)==dstFile & validMoves(:,2)==dstRank);
            if ~isLegal
                error('Stockfish returned illegal move %s for the current MATLAB board state.', mv.uci);
            end

            this.performMove(srcFile, srcRank, dstFile, dstRank, mv.promotion);
        end

        function notifyStockfishError(this, err)
            try
                this.stopMoveTimer();
            catch
            end
            msg = err.message;
            if isempty(msg)
                msg = 'Unknown Stockfish error.';
            end
            errordlg(sprintf('Stockfish could not move:\n%s', msg), 'Stockfish error', 'modal');
        end


        function updateCheckMarkers(this)
            if isempty(this.chessBoardModel) || isempty(this.gameController)
                return;
            end
            this.updateKingCheckMarkerForColor('w');
            this.updateKingCheckMarkerForColor('b');
        end

        function updateKingCheckMarkerForColor(this, color)
            kingPiece = this.findKingPiece(color);
            if isempty(kingPiece)
                return;
            end
            file = kingPiece.position(1);
            rank = kingPiece.position(2);
            if file < 1 || file > 8 || rank < 1 || rank > 8
                return;
            end
            btn = this.chessBoardModel.chessBoardBoxes(file, rank).button;
            if ~ishandle(btn)
                return;
            end
            baseImg = this.pieceImageForPiece(kingPiece);
            if isempty(baseImg)
                return;
            end
            try
                inCheck = this.gameController.isKingInCheck(color);
            catch
                inCheck = false;
            end
            if inCheck
                set(btn, 'CData', ChessBoardGUI.addCheckExclamation(baseImg));
            else
                set(btn, 'CData', baseImg);
            end
        end

        function kingPiece = findKingPiece(this, color)
            kingPiece = [];
            for file = 1:8
                for rank = 1:8
                    btn = this.chessBoardModel.chessBoardBoxes(file, rank).button;
                    if ~ishandle(btn); continue; end
                    p = btn.UserData;
                    if isempty(p) || ischar(p); continue; end
                    if p.id == 'K' && p.color == color
                        kingPiece = p;
                        return;
                    end
                end
            end
        end

        function img = pieceImageForPiece(~, piece)
            img = [];
            if isempty(piece) || ischar(piece)
                return;
            end
            try
                img = ChessBoardGUI.createRGB(sprintf('resources/%s%s.png', piece.id, upper(piece.color)));
            catch
                img = [];
            end
        end

        function notifyCheck(this, checkedColor) %#ok<INUSD>
            % Intentionally silent. A successful checking move should not
            % interrupt either player with a popup. The only check-related
            % popup is notifyNoCoverCheck(), which is called after an
            % invalid attempted move that leaves the mover's own king in
            % check.
        end

        function notifyDraw(this, status)
            if this.endDialogShown
                return;
            end
            this.endDialogShown = true;

            reason = this.drawReasonForStatus(status);
            if isempty(reason)
                reason = 'draw';
            end
            bg = [1 1 1];
            fnt = [0 0 0];
            warn = dialog('Name','Draw','Position',[500 500 560 210], ...
                'Resize','off','Color',bg);
            uicontrol(warn,'Style','pushbutton','String','Close', ...
                'Position',[390 22 100 36],'Enable','on','Callback','close all');
            uicontrol(warn,'Style','pushbutton','String','Review Game', ...
                'Position',[235 22 140 36],'Enable','on', ...
                'Callback', @(src,~) this.onReviewClicked(src));
            uicontrol(warn,'Style','pushbutton','String','New Game', ...
                'Position',[80 22 140 36],'Enable','on', ...
                'Callback',@(~,~) run('ChessMasters'));
            uicontrol(warn,'Style','text', ...
                'String',sprintf('The game is a draw by %s.', reason), ...
                'FontSize',16,'HorizontalAlignment','center', ...
                'Position',[25 105 510 55], ...
                'BackgroundColor',bg,'ForegroundColor',fnt);
        end

        function notifyEnd(this)
            if this.endDialogShown
                return;
            end
            this.endDialogShown = true;

            timerState = this.currentTimerState();
            if ~isempty(timerState) && isfield(timerState, 'expiredColor') && ~isempty(timerState.expiredColor)
                winnerColor = this.oppositeColor(timerState.expiredColor);
            elseif this.gameController.whoPlays() == 'w'
                winnerColor = 'b';
            else
                winnerColor = 'w';
            end

            if winnerColor == 'b'
                msg='black'; bg=[1 1 1]; fnt=[0 0 0];
            else
                msg='white'; bg=[0 0 0]; fnt=[1 1 1];
            end
            warn = dialog('Name','End','Position',[500 500 540 200], ...
                'Resize','off','Color',bg);
            uicontrol(warn,'Style','pushbutton','String','Close', ...
                'Position',[370 22 100 36],'Enable','on','Callback','close all');
            uicontrol(warn,'Style','pushbutton','String','Review Game', ...
                'Position',[225 22 130 36],'Enable','on', ...
                'Callback', @(src,~) this.onReviewClicked(src));
            uicontrol(warn,'Style','pushbutton','String','New Game', ...
                'Position',[80 22 130 36],'Enable','on', ...
                'Callback',@(~,~) run('ChessMasters'));
            uicontrol(warn,'Style','text','String',['The ' msg ' player has won!'], ...
                'FontSize',16,'HorizontalAlignment','center', ...
                'Position',[25 105 490 50], ...
                'BackgroundColor',bg,'ForegroundColor',fnt);
        end

        function onReviewClicked(this, dlgSrc)
            % Close the end-of-game dialog and switch to review mode.
            % Walk up to find the figure that owns dlgSrc (it's the
            % dialog itself, since that's what the button parent is).
            try
                f = ancestor(dlgSrc, 'figure');
                if ~isempty(f) && ishandle(f); delete(f); end
            catch
            end
            this.enterReviewMode();
        end

        function enterReviewMode(this)
            % Switch into review mode. Stops timers (move timer +
            % poll timer), suppresses any pending notifications, and
            % updates the status bar. The board stays where it is --
            % at the final position by default. The user navigates
            % via Prev/Next/Live and the History viewer.
            this.isReviewMode = true;
            this.reviewVariationActive = false;
            this.rememberAnalysisEnginePathFromGame();
            if isempty(this.analysisEnginePath)
                msg = {'Review mode active.', ...
                    'Use <, >, or History to choose a position.', ...
                    'Choose Engine... once, then click Analyze Position.'};
            else
                msg = {'Review mode active.', ...
                    'Using the Stockfish engine path from this game.', ...
                    'Use <, >, or History, then click Analyze Position.'};
            end
            this.clearAnalysisBestMove(msg);

            % Drop any in-flight game-management state.
            if ~isempty(this.premoveQueue)
                this.clearPremoveQueueHighlights();
                this.premoveQueue = {};
            end
            this.clearSelection();
            this.stopMoveTimer();
            this.stopAutoPoll();
            this.updateStatusBar();
            this.updateActionButtons();
        end

        function notifyNoCoverCheck(this)
            if this.gameController.whoPlays() == 'w'
                msg='white'; bg=[1 1 1]; fnt=[0 0 0];
            else
                msg='black'; bg=[0 0 0]; fnt=[1 1 1];
            end
            warn = dialog('Name','Invalid Move','Position',[500 500 640 220], ...
                'Resize','off','Color',bg);
            uicontrol(warn,'Style','pushbutton','String','Close', ...
                'Position',[280 20 80 36],'Enable','on','Callback','close');
            uicontrol(warn,'Style','text', ...
                'String',sprintf('Invalid move! The %s king is in check and must be protected.', msg), ...
                'FontSize',16,'HorizontalAlignment','center', ...
                'Position',[25 85 590 80], ...
                'BackgroundColor',bg,'ForegroundColor',fnt);
        end

        function promoteToPiece(this, pawn, promotionChoice)
            if isempty(promotionChoice)
                promotionChoice = 'Q';
            end
            promotionChoice = upper(char(promotionChoice));
            promotionChoice = promotionChoice(1);
            switch promotionChoice
                case 'R'
                    cls = @Rook;   letter = 'R';
                case 'B'
                    cls = @Bishop; letter = 'B';
                case 'N'
                    cls = @Knight; letter = 'N';
                otherwise
                    cls = @Queen;  letter = 'Q';
            end
            player = upper(pawn.color);
            boxes = this.chessBoardModel.chessBoardBoxes(pawn.position(1), pawn.position(2));
            this.chessBoardModel.chessBoardMap(pawn.position(2), pawn.position(1)) = letter;
            set(boxes.button, ...
                'CData',    ChessBoardGUI.createRGB(['resources/' letter player '.png']), ...
                'UserData', cls(this.chessBoardModel, pawn.color, pawn.position));
        end

        function promote(this, pawn)
            if this.gameController.whoPlays() == 'w'
                bg=[1 1 1]; fnt=[0 0 0];
            else
                bg=[0 0 0]; fnt=[1 1 1];
            end
            warn = dialog('Name','Promotion','Position',[500 500 400 175], ...
                'Resize','off','Color',bg);
            uicontrol(warn,'Style','popup', ...
                'String',{'Rook','Bishop','Knight','Queen'}, 'FontSize',22, ...
                'Position',[140 0 120 90], ...
                'Callback',{@popup_callback, this, pawn});
            uicontrol(warn,'Style','text','String','Promote your pawn to a different piece!', ...
                'FontSize',22,'Position',[0 100 400 50], ...
                'BackgroundColor',bg,'ForegroundColor',fnt);
            % Block until the user picks a piece (via the popup
            % callback below, which closes this dialog). This lets
            % performMove know the promotion is resolved before it
            % decides whether to auto-commit.
            uiwait(warn);
            function popup_callback(hObject, ~, this, movedPiece)
                selectedIndex = get(hObject,'value');
                player = upper(movedPiece.color);
                boxes = this.chessBoardModel.chessBoardBoxes( ...
                    movedPiece.position(1), movedPiece.position(2));
                switch selectedIndex
                    case 1, cls = @Rook;   letter = 'R';
                    case 2, cls = @Bishop; letter = 'B';
                    case 3, cls = @Knight; letter = 'N';
                    otherwise, cls = @Queen; letter = 'Q';
                end
                this.chessBoardModel.chessBoardMap(movedPiece.position(2), movedPiece.position(1)) = letter;
                set(boxes.button, ...
                    'CData',    ChessBoardGUI.createRGB(['resources/' letter player '.png']), ...
                    'UserData', cls(this.chessBoardModel, movedPiece.color, movedPiece.position));
                close;
            end
        end
    end

    methods (Static)
        function img = addCheckExclamation(img)
            if isempty(img)
                return;
            end
            [h, w, ~] = size(img);
            x0 = max(1, round(0.70*w));
            x1 = min(w, round(0.88*w));
            y0 = max(1, round(0.14*h));
            y1 = min(h, round(0.54*h));
            dotY0 = max(1, round(0.61*h));
            dotY1 = min(h, round(0.72*h));
            dotX0 = max(1, round(0.73*w));
            dotX1 = min(w, round(0.85*w));
            outlinePad = max(1, round(0.025*w));

            % Thin dark outline first, then the red mark. This keeps the
            % symbol visible over both white and black kings.
            xo0 = max(1, x0-outlinePad); xo1 = min(w, x1+outlinePad);
            yo0 = max(1, y0-outlinePad); yo1 = min(h, y1+outlinePad);
            dxo0 = max(1, dotX0-outlinePad); dxo1 = min(w, dotX1+outlinePad);
            dyo0 = max(1, dotY0-outlinePad); dyo1 = min(h, dotY1+outlinePad);
            img(yo0:yo1, xo0:xo1, :) = 0;
            img(dyo0:dyo1, dxo0:dxo1, :) = 0;
            img(y0:y1, x0:x1, 1) = 1; img(y0:y1, x0:x1, 2) = 0; img(y0:y1, x0:x1, 3) = 0;
            img(dotY0:dotY1, dotX0:dotX1, 1) = 1; img(dotY0:dotY1, dotX0:dotX1, 2) = 0; img(dotY0:dotY1, dotX0:dotX1, 3) = 0;
        end

        function safeCloseMsgbox(h, timerObj)
            % Close the msgbox if it's still open, then clean up the
            % one-shot auto-dismiss timer.
            try
                if ishandle(h); close(h); end
            catch
            end
            try
                stop(timerObj);
                delete(timerObj);
            catch
            end
        end

        function playing_figure_rgb = createRGB(name)
            [playing_figure_rgb, ~, alpha] = imread(name);
            playing_figure_rgb = double(playing_figure_rgb)/255;
            playing_figure_rgb((alpha/255)==0) = NaN;
        end

        function img = makeDotImage(sz, r, rgb)
            img = nan(sz, sz, 3);
            [X, Y] = meshgrid(1:sz, 1:sz);
            mask = (X - sz/2).^2 + (Y - sz/2).^2 <= r^2;
            for c = 1:3
                layer = img(:,:,c);
                layer(mask) = rgb(c);
                img(:,:,c) = layer;
            end
        end
    end
end