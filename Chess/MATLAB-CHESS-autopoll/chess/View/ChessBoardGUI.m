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
        orientation              = 'w'    % 'w' or 'b'
        figureHandle
        statusText
        refreshButton
        pauseButton
        endTurnButton            = []
        undoButton               = []
        addPremoveButton         = []
        clearPremovesButton      = []
        cancelPremoveEntryButton = []
        timerWhiteText
        timerBlackText
        moveTimerObj             = []
        pollTimerObj             = []     % network-mode auto-refresh timer
        localTimerState          = []
        timerExpiredLocal        = false

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
        % Queue of conditional premoves. Each entry is a struct with
        % oppFrom/oppTo (the predicted opponent move) and myFrom/myTo
        % (our response). Stored ONLY here in-process -- never written
        % to the shared JSON -- so the opponent cannot see it.
        premoveQueue             = {}

        % In-progress premove entry (while the user is choosing squares
        % for a new premove). Struct with fields:
        %   .step   1=pick opp src, 2=pick opp dst, 3=pick my src, 4=pick my dst
        %   .oppFrom,.oppTo,.myFrom  (accumulated as user clicks)
        %   .tempHighlights          cell of {file,rank,bg} to restore
        premoveEntry             = []

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
        COLOR_PREMOVE_OPP   = [0.9 0.3 0.3]     % predicted opponent from/to (red)
        COLOR_PREMOVE_MINE  = [0.6 0.82 1]    % queued response from/to (blue)
        COLOR_PREMOVE_ENTRY = [0.85 0.72 1]   % in-progress premove-entry partials (violet)
        TILE_PX          = 100
        BOARD_ORIGIN_X   = 20
        BOARD_ORIGIN_Y   = 40
        TOP_BAR_HEIGHT   = 60

        % Auto-poll (network mode): each tick is scheduled POLL_MIN_SEC
        % + rand*POLL_JITTER_SEC seconds after the previous one fires,
        % so two clients that opened the same game never fall into
        % phase-lock and hammer the share point simultaneously.
        POLL_MIN_SEC     = 5
        POLL_JITTER_SEC  = 5
    end

    methods
        function this = ChessBoardGUI(chessBoardModel, gameController, netGame, orientation, localTimerState)
            this.gameController  = gameController;
            this.chessBoardModel = chessBoardModel;
            if nargin >= 3 && ~isempty(netGame);     this.netGame     = netGame;     end
            if nargin >= 4 && ~isempty(orientation); this.orientation = orientation; end
            if nargin >= 5 && ~isempty(localTimerState); this.localTimerState = GameState.normalizeTimerState(localTimerState); end

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
            this.updateStatusBar();
            if isempty(this.netGame)
                this.syncClockAfterBoardLoad([], this.currentStateStruct(), true);
            else
                this.handleNetworkInitialOpen();
                this.startAutoPoll();
            end
        end

        function createGUI(this)
            figH = this.BOARD_ORIGIN_Y + 8*this.TILE_PX + 35 + this.TOP_BAR_HEIGHT;
            h = figure('Name','Chess Master', ...
                'Position',[300 150 1035 figH], ...
                'MenuBar','none','NumberTitle','off', ...
                'Color',[1 1 1],'Resize','off', ...
                'CloseRequestFcn', @(~,~) this.onFigureClosed());
            this.figureHandle = h;

            topBarY = figH - this.TOP_BAR_HEIGHT + 10;
            this.statusText = uicontrol(h, 'Style','text', 'String','', ...
                'FontSize',13, 'HorizontalAlignment','left', ...
                'BackgroundColor',[1 1 1], ...
                'Position',[this.BOARD_ORIGIN_X topBarY 430 30]);
            this.timerWhiteText = uicontrol(h, 'Style','text', 'String','White  --:--', ...
                'FontSize',12, 'HorizontalAlignment','right', ...
                'BackgroundColor',[1 1 1], 'Position',[455 topBarY 95 30]);
            this.timerBlackText = uicontrol(h, 'Style','text', 'String','Black  --:--', ...
                'FontSize',12, 'HorizontalAlignment','right', ...
                'BackgroundColor',[1 1 1], 'Position',[555 topBarY 95 30]);

            % End-Turn and Undo share slots with Add-Premove and
            % Clear-Premoves -- only the set relevant to the current
            % game state is made Visible. See updateActionButtons().
            this.endTurnButton = uicontrol(h, 'Style','pushbutton', ...
                'String','End Turn', 'FontSize',11, ...
                'Position',[655 topBarY 75 30], ...
                'Visible','off', ...
                'Callback', @(~,~) this.onEndTurnClicked());
            this.undoButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Undo', 'FontSize',11, ...
                'Position',[735 topBarY 70 30], ...
                'Visible','off', ...
                'Callback', @(~,~) this.onUndoMoveClicked());
            this.addPremoveButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Premove', 'FontSize',11, ...
                'Position',[655 topBarY 75 30], ...
                'Visible','off', ...
                'Callback', @(~,~) this.onAddPremoveClicked());
            this.clearPremovesButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Clear Pre', 'FontSize',10, ...
                'Position',[735 topBarY 70 30], ...
                'Visible','off', ...
                'Callback', @(~,~) this.onClearPremovesClicked());
            this.cancelPremoveEntryButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Cancel', 'FontSize',11, ...
                'Position',[735 topBarY 70 30], ...
                'Visible','off', ...
                'Callback', @(~,~) this.onCancelPremoveEntryClicked());
            this.refreshButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Refresh', 'FontSize',11, ...
                'Position',[810 topBarY 70 30], ...
                'Enable',   this.refreshEnableFlag(), ...
                'Callback', @(~,~) this.onRefreshClicked());
            this.pauseButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Pause', 'FontSize',11, ...
                'Position',[885 topBarY 65 30], ...
                'Enable','off', ...
                'Callback', @(~,~) this.onPauseResumeClicked());

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
                % File letters (bottom)
                uicontrol('Style','text', 'Parent',h, ...
                    'Position',[this.BOARD_ORIGIN_X + this.TILE_PX*(k-1) + 40, ...
                                this.BOARD_ORIGIN_Y - 20, 20, 20], ...
                    'FontSize',15,'BackgroundColor',[1 1 1], 'String', fileLabel);
                % File letters (top)
                uicontrol('Style','text', 'Parent',h, ...
                    'Position',[this.BOARD_ORIGIN_X + this.TILE_PX*(k-1) + 40, ...
                                this.BOARD_ORIGIN_Y + this.TILE_PX*8, 20, 20], ...
                    'FontSize',15,'BackgroundColor',[1 1 1], 'String', fileLabel);
                % Rank numbers (left)
                uicontrol('Style','text', 'Parent',h, ...
                    'Position',[0, this.BOARD_ORIGIN_Y + this.TILE_PX*(k-1) + 40, ...
                                20, 20], ...
                    'FontSize',15,'BackgroundColor',[1 1 1], 'String', rankLabel);
                % Rank numbers (right)
                uicontrol('Style','text', 'Parent',h, ...
                    'Position',[this.BOARD_ORIGIN_X + this.TILE_PX*8, ...
                                this.BOARD_ORIGIN_Y + this.TILE_PX*(k-1) + 40, ...
                                20, 20], ...
                    'FontSize',15,'BackgroundColor',[1 1 1], 'String', rankLabel);
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
            if ~strcmp(this.gameController.gameStatus(), 'active'); return; end
            if this.isClockExpired(); return; end
            if this.isGamePaused(); return; end

            % Pending-handoff: the mover has already played their move
            % locally and must either commit (End Turn) or revert (Undo)
            % via the dedicated buttons. Board clicks are inert.
            if ~isempty(this.pendingMove)
                return;
            end

            % Premove-entry: route clicks through the 4-step flow.
            if ~isempty(this.premoveEntry) && this.premoveEntry.step >= 1
                this.handlePremoveEntryClick(file, rank);
                return;
            end

            if ~isempty(this.netGame) && ~this.netGame.isMyTurn(); return; end

            piece    = btn.UserData;
            hasPiece = ~isempty(piece) && ~ischar(piece);
            whoPlays = this.gameController.whoPlays();

            if isempty(this.selectedFile)
                if hasPiece && piece.color == whoPlays
                    this.selectSquare(file, rank);
                end
                return;
            end

            if file == this.selectedFile && rank == this.selectedRank
                this.clearSelection();
                return;
            end
            if hasPiece && piece.color == whoPlays
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

        function selectSquare(this, file, rank)
            btn = this.chessBoardModel.chessBoardBoxes(file, rank).button;
            this.selectedFile   = file;
            this.selectedRank   = rank;
            this.selectedOrigBg = get(btn, 'BackgroundColor');
            set(btn, 'BackgroundColor', this.COLOR_SELECTED);
            this.showLegalMoves(btn.UserData);
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
        function performMove(this, srcFile, srcRank, dstFile, dstRank)
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
                this.promote(movedPiece);
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
            pending.isPromotion        = isPromotion;
            this.pendingMove           = pending;

            this.paintPendingMoveHighlight();

            % Promotion moves auto-commit (see function header).
            if isPromotion
                this.commitPendingMove();
                return;
            end

            this.updateStatusBar();
            this.updateActionButtons();
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

            checkState = '';
            if this.gameController.isKingInCheck(opponentColor)
                if ~this.gameController.hasAnyLegalMove(opponentColor)
                    checkState = 'checkmate';
                else
                    checkState = 'check';
                end
            end

            if ~isempty(this.netGame)
                state = this.buildStateAfterMove(p.srcFile, p.srcRank, p.dstFile, p.dstRank, ...
                    moverProxy, p.wasCapture, checkState, p.castleInfo, p.enPassantInfo, nextTimerState);
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
            end

            this.pendingMove = [];

            if strcmp(checkState, 'checkmate')
                this.notifyEnd();
            end
            if isempty(this.netGame)
                this.startTimerForColorIfEnabled(this.gameController.whoPlays(), false);
            end
            this.updateStatusBar();
            this.updateActionButtons();
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
                movedPiece, wasCapture, checkState, castleInfo, enPassantInfo, nextTimerState)
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
            state.lastMove = struct( ...
                'from',      [srcRank srcFile], ...
                'to',        [dstRank dstFile], ...
                'piece',     finalPieceId, ...
                'color',     finalColor, ...
                'capture',   wasCapture, ...
                'promotion', wasPromotion, ...
                'castle',    castleInfo.isCastle, ...
                'castleSide', castleInfo.side, ...
                'enPassant', enPassantInfo.isEnPassant);
            state.history = [prev.history; {state.lastMove}];
            if isempty(checkState)
                state.status = 'active';
            else
                state.status = checkState;
            end
            state.enPassantInfo = this.chessBoardModel.enPassantInfo;
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
        % Each queued premove is conditional: it fires only if the
        % opponent's next actual move matches the predicted opponent
        % move (oppFrom -> oppTo) stored in the head of the queue.
        % On a mismatch, the whole queue is discarded, because every
        % queued plan assumed the predicted move would happen.

        function onAddPremoveClicked(this)
            if isempty(this.netGame); return; end
            if ~isempty(this.pendingMove); return; end
            if this.netGame.isMyTurn(); return; end   % only while waiting
            if this.isClockExpired() || this.isGamePaused(); return; end

            this.premoveEntry = struct( ...
                'step',            1, ...
                'oppFrom',         [], ...
                'oppTo',           [], ...
                'myFrom',          [], ...
                'tempHighlights',  {{}});
            this.clearSelection();
            this.updateStatusBar();
            this.updateActionButtons();
        end

        function onCancelPremoveEntryClicked(this)
            if isempty(this.premoveEntry); return; end
            this.restorePremoveEntryHighlights();
            this.premoveEntry = [];
            this.updateStatusBar();
            this.updateActionButtons();
        end

        function onClearPremovesClicked(this)
            if isempty(this.premoveQueue); return; end
            this.clearPremoveQueueHighlights();
            this.premoveQueue = {};
            this.updateStatusBar();
            this.updateActionButtons();
        end

        function handlePremoveEntryClick(this, file, rank)
            if isempty(this.premoveEntry); return; end
            % NOTE: we deliberately mutate this.premoveEntry directly
            % rather than working on a local copy. MATLAB structs are
            % value-copied, and stampPremoveEntrySquare needs to
            % append to .tempHighlights -- if that happened on a
            % local we'd lose it on write-back.
            btn = this.chessBoardModel.chessBoardBoxes(file, rank).button;
            piece = btn.UserData;
            hasPiece = ~isempty(piece) && ~ischar(piece);

            myColor = this.netGame.myColor;
            oppColor = this.oppositeColor(myColor);

            switch this.premoveEntry.step
                case 1  % pick opponent piece (source of predicted move)
                    if ~hasPiece || piece.color ~= oppColor
                        return;   % must be an opponent piece
                    end
                    this.premoveEntry.oppFrom = [file rank];
                    this.stampPremoveEntrySquare(file, rank, this.COLOR_PREMOVE_ENTRY);
                    this.premoveEntry.step = 2;
                case 2  % pick opponent destination
                    if isequal([file rank], this.premoveEntry.oppFrom)
                        return;   % can't be the same square
                    end
                    this.premoveEntry.oppTo = [file rank];
                    this.stampPremoveEntrySquare(file, rank, this.COLOR_PREMOVE_ENTRY);
                    this.premoveEntry.step = 3;
                case 3  % pick my piece (source of response)
                    if ~hasPiece || piece.color ~= myColor
                        return;
                    end
                    this.premoveEntry.myFrom = [file rank];
                    this.stampPremoveEntrySquare(file, rank, this.COLOR_PREMOVE_ENTRY);
                    this.premoveEntry.step = 4;
                case 4  % pick my destination and commit premove
                    if isequal([file rank], this.premoveEntry.myFrom)
                        return;
                    end
                    pm = struct( ...
                        'oppFrom', this.premoveEntry.oppFrom, ...
                        'oppTo',   this.premoveEntry.oppTo, ...
                        'myFrom',  this.premoveEntry.myFrom, ...
                        'myTo',    [file rank]);
                    % Unstamp the entry-in-progress tint (the queue
                    % painter will paint the real premove tints).
                    this.restorePremoveEntryHighlights();
                    this.premoveEntry = [];
                    this.premoveQueue{end+1} = pm; %#ok<AGROW>
                    this.paintPremoveHighlights(pm);
            end
            this.updateStatusBar();
            this.updateActionButtons();
        end

        function stampPremoveEntrySquare(this, file, rank, color)
            % Remember the pre-stamp bg so we can restore on cancel
            % without assuming anything about what was there.
            btn = this.chessBoardModel.chessBoardBoxes(file, rank).button;
            if ~ishandle(btn); return; end
            snap = struct('file', file, 'rank', rank, ...
                          'bg',   get(btn, 'BackgroundColor'));
            this.premoveEntry.tempHighlights{end+1} = snap;
            set(btn, 'BackgroundColor', color);
        end

        function restorePremoveEntryHighlights(this)
            if isempty(this.premoveEntry); return; end
            if ~isfield(this.premoveEntry, 'tempHighlights'); return; end
            th = this.premoveEntry.tempHighlights;
            for k = 1:numel(th)
                s = th{k};
                btn = this.chessBoardModel.chessBoardBoxes(s.file, s.rank).button;
                if ishandle(btn)
                    set(btn, 'BackgroundColor', s.bg);
                end
            end
            this.premoveEntry.tempHighlights = {};
        end

        function paintPremoveHighlights(this, pm)
            % Paints one premove's four squares. Callers should later
            % call clearPremoveQueueHighlights before rebuilding the
            % board so we don't strand tints on squares that have
            % moved on.
            this.tintSquare(pm.oppFrom(1), pm.oppFrom(2), this.COLOR_PREMOVE_OPP);
            this.tintSquare(pm.oppTo(1),   pm.oppTo(2),   this.COLOR_PREMOVE_OPP);
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
                pts = [pm.oppFrom; pm.oppTo; pm.myFrom; pm.myTo];
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

        % Called after a refresh brings in an opponent move. If the
        % actual move matches the head-of-queue prediction, tries to
        % auto-fire our response. If the response is illegal given
        % the new position, discards the queue. If the prediction is
        % wrong, discards the queue.
        %
        % Returns true iff a premove was fired and committed.
        function fired = tryFirePremove(this, newState)
            fired = false;
            if isempty(this.netGame);            return; end
            if isempty(this.premoveQueue);       return; end
            if ~this.netGame.isMyTurn();         return; end  % only on our turn
            if ~strcmp(newState.status, 'active') && ~strcmp(newState.status, 'check')
                % Game is over (checkmate/timeout/paused etc.) -- don't fire.
                this.clearPremoveQueueHighlights();
                this.premoveQueue = {};
                return;
            end

            head = this.premoveQueue{1};
            if ~this.premoveMatchesOpponentMove(head, newState)
                % Prediction broken -- discard all.
                this.clearPremoveQueueHighlights();
                this.premoveQueue = {};
                return;
            end

            % Our response must still be legal given the new position.
            srcBtn = this.chessBoardModel.chessBoardBoxes(head.myFrom(1), head.myFrom(2)).button;
            mine = srcBtn.UserData;
            if isempty(mine) || ischar(mine) || mine.color ~= this.netGame.myColor
                this.clearPremoveQueueHighlights();
                this.premoveQueue = {};
                return;
            end
            moves = mine.ValidMoves();
            isLegalShape = ~isempty(moves) && any(moves(:,1)==head.myTo(1) & moves(:,2)==head.myTo(2));
            if ~isLegalShape
                this.clearPremoveQueueHighlights();
                this.premoveQueue = {};
                return;
            end
            if ~this.gameController.isLegalMoveForColor(mine, head.myTo)
                % Move would expose our own king to check.
                this.clearPremoveQueueHighlights();
                this.premoveQueue = {};
                return;
            end

            % Consume the head premove (unhighlight its four squares
            % BEFORE the move, since the board is about to change).
            this.clearPremoveQueueHighlights();
            this.premoveQueue(1) = [];

            % Premove-fired moves auto-commit -- the user pre-consented
            % by queuing the premove. performMove itself only sets
            % pendingMove; commitPendingMove finishes the handoff.
            this.performMove(head.myFrom(1), head.myFrom(2), head.myTo(1), head.myTo(2));
            if ~isempty(this.pendingMove)
                this.commitPendingMove();
            end

            % Repaint any remaining queued premoves (their squares
            % were cleared above).
            this.paintAllPremoveHighlights();
            fired = true;
        end

        function tf = premoveMatchesOpponentMove(~, pm, newState)
            tf = false;
            if ~isfield(newState, 'lastMove') || isempty(newState.lastMove)
                return;
            end
            mv = newState.lastMove;
            if ~isstruct(mv) || ~isfield(mv, 'from') || ~isfield(mv, 'to')
                return;
            end
            % GameState stores moves as [rank file]; premoves store [file rank].
            fromFR = [mv.from(2) mv.from(1)];
            toFR   = [mv.to(2)   mv.to(1)];
            tf = isequal(fromFR, pm.oppFrom) && isequal(toFR, pm.oppTo);
        end

        function updateActionButtons(this)
            if isempty(this.endTurnButton) || ~ishandle(this.endTurnButton); return; end

            havePending  = ~isempty(this.pendingMove);
            inEntry      = ~isempty(this.premoveEntry);
            haveNet      = ~isempty(this.netGame);
            myTurn       = haveNet && this.netGame.isMyTurn();
            canAddPre    = haveNet && ~havePending && ~myTurn ...
                           && ~this.isClockExpired() && ~this.isGamePaused();
            havePremoves = ~isempty(this.premoveQueue);

            % Slot layout (see createGUI for pixel positions):
            %   slot 1 (x=655): End Turn  OR  Premove   (mutually exclusive)
            %   slot 2 (x=735): Undo      OR  Clear Pre OR Cancel
            showEndTurn  = havePending;
            showUndo     = havePending;
            showAddPre   = canAddPre && ~inEntry;
            showClearPre = havePremoves && ~inEntry && ~havePending;
            showCancel   = inEntry;

            set(this.endTurnButton,            'Visible', onoff(showEndTurn));
            set(this.undoButton,               'Visible', onoff(showUndo));
            set(this.addPremoveButton,         'Visible', onoff(showAddPre));
            set(this.clearPremovesButton,      'Visible', onoff(showClearPre));
            set(this.cancelPremoveEntryButton, 'Visible', onoff(showCancel));

            % Refresh is unsafe while a pending move exists (would
            % wipe our visual move). Disable in that case.
            if havePending
                set(this.refreshButton, 'Enable', 'off');
            else
                set(this.refreshButton, 'Enable', this.refreshEnableFlag());
            end

            function s = onoff(b)
                if b; s = 'on'; else; s = 'off'; end
            end
        end

        function onRefreshClicked(this)
            if isempty(this.netGame); return; end
            if ~isempty(this.pendingMove)
                % Shouldn't happen -- button is disabled -- but guard
                % anyway; refreshing here would wipe the pending move.
                return;
            end
            % If the user had a premove entry in progress, cancel it.
            if ~isempty(this.premoveEntry)
                this.onCancelPremoveEntryClicked();
            end
            this.clearSelection();

            % The board rebuild inside applyToModel does NOT touch
            % square backgrounds, but any square that a premove
            % tinted may no longer be on the same piece/logical role
            % after the opponent's move. Clear the tints first, then
            % repaint whichever survive the tryFirePremove step.
            this.clearPremoveQueueHighlights();

            prevState = this.netGame.lastSeenState;
            try
                state = this.netGame.load();
            catch err
                % Load failed -- restore the tints we just cleared so
                % the UI is unchanged.
                this.paintAllPremoveHighlights();
                errordlg(err.message, 'Refresh failed', 'modal');
                return;
            end
            boardUpdated = isempty(prevState) || state.moveNumber ~= prevState.moveNumber;
            this.suppressInput = true;
            c = onCleanup(@() this.unsuppressInput());
            GameState.applyToModel(state, this.chessBoardModel, ...
                this.gameController, this);
            clear c;
            if boardUpdated
                this.flashLastMove(state);
            end
            this.syncClockAfterBoardLoad(prevState, state, boardUpdated);

            % If the opponent just moved and we have a queued premove
            % predicting that move, fire it. tryFirePremove also
            % handles the mismatch case (queue discarded) and the
            % illegal-response case (queue discarded).
            if boardUpdated
                this.tryFirePremove(state);
            end
            % Whatever survived (the firing cleared the one that
            % fired; the rest stays queued) is repainted here.
            this.paintAllPremoveHighlights();

            this.updateStatusBar();
            this.updateActionButtons();

            % Push the next auto-poll tick out by a fresh jittered
            % interval. Otherwise a user-driven Refresh followed by
            % a tick that was already almost due would produce two
            % file reads within a second of each other.
            this.resetAutoPoll();
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

            shouldStartNow = false;
            if firstOpenForMe && this.netGame.isMyTurn() && strcmp(this.netGame.lastSeenState.status, 'active')
                shouldStartNow = true;
            elseif this.netGame.lastSeenState.moveNumber == 1 && this.netGame.isMyTurn() && strcmp(this.netGame.lastSeenState.status, 'active')
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
            if ~isempty(timerState) && isfield(timerState, 'expiredColor') && ~isempty(timerState.expiredColor)
                loser = 'White'; if timerState.expiredColor == 'b'; loser = 'Black'; end
                msg = sprintf('%s flag fell', loser);
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
            elseif ~isempty(this.premoveEntry)
                msg = this.premoveEntryStatusMessage();
            elseif ~isempty(this.pendingMove)
                moverStr = 'White';
                if this.pendingMove.moverColor == 'b'; moverStr = 'Black'; end
                msg = sprintf('%s: move pending  --  End Turn to send, Undo to take back', moverStr);
            elseif isempty(this.netGame)
                if this.gameController.whoPlays() == 'w'
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
                    if nQueued == 0
                        msg = sprintf('You are %s  --  waiting for opponent  (move %d, auto-syncing)', ...
                            myStr, s.moveNumber);
                    else
                        msg = sprintf('You are %s  --  waiting  (move %d, %d premove%s queued)', ...
                            myStr, s.moveNumber, nQueued, ternary(nQueued==1,'','s'));
                    end
                end
                if ~strcmp(s.status, 'active')
                    msg = sprintf('%s  |  %s', msg, upper(s.status));
                end
            end
            set(this.statusText, 'String', msg);
            this.refreshTimerLabels();
            this.updatePauseButton();
            this.updateActionButtons();

            function s = ternary(cond, a, b)
                if cond; s = a; else; s = b; end
            end
        end

        function msg = premoveEntryStatusMessage(this)
            e = this.premoveEntry;
            switch e.step
                case 1
                    msg = 'Premove 1/4: click opponent piece to predict';
                case 2
                    msg = 'Premove 2/4: click opponent''s predicted destination';
                case 3
                    msg = 'Premove 3/4: click your response piece';
                case 4
                    msg = 'Premove 4/4: click your response destination';
                otherwise
                    msg = 'Premove entry';
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
            if ~timerState.enabled || ~isempty(timerState.expiredColor)
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
            if ~timerState.enabled || ~isempty(timerState.expiredColor)
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
                state = struct('timer', this.currentTimerState(), 'status', 'active', ...
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
            if ~timerState.enabled || ~isempty(timerState.expiredColor)
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
            if ~timerState.enabled || ~timerState.running || ~isempty(timerState.expiredColor) || this.isGamePaused()
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
        %   - this.premoveEntry         (user is clicking through the
        %                                4-step premove entry flow)
        %   - this.selectedFile         (a piece is picked up)
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
                if ~isempty(this.premoveEntry); return; end
                if ~isempty(this.selectedFile); return; end

                % Cheap: just peek at moveNumber/updatedAt. Swallows
                % transient read errors internally (returns false),
                % which is exactly what we want for a background poll.
                if ~this.netGame.hasOpponentMoved()
                    return;
                end

                % Something changed on disk -- do the heavy refresh.
                % onRefreshClicked already calls resetAutoPoll at its
                % end; our onCleanup will then reset it again, which
                % is harmless (scheduleNextPoll always stops the old
                % timer first).
                this.onRefreshClicked();
            catch
                % Swallow. Cleanup reschedules, so next tick still fires.
            end
        end

        function scheduleNextPollIfAlive(this)
            if ~ishandle(this.figureHandle); return; end
            if isempty(this.netGame); return; end
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
                if ~isempty(this.premoveEntry)
                    this.onCancelPremoveEntryClicked();
                end
                if ~isempty(this.netGame)
                    this.netGame.setCachedTimer(timerState);
                    this.netGame.setCachedStatus('timeout');
                    try
                        this.netGame.save(this.netGame.lastSeenState);
                    catch
                    end
                end
                this.updateStatusBar();
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
            delete(this.figureHandle);
        end

        % ---------------------------------------------------------------
        % Legacy dialogs, lightly cleaned up
        % ---------------------------------------------------------------
        function notifyCheck(this)
            if this.gameController.whoPlays() == 'w'
                msg='white'; bg=[1 1 1]; fnt=[0 0 0];
            else
                msg='black'; bg=[0 0 0]; fnt=[1 1 1];
            end
            warn = dialog('Name','Check','Position',[500 500 420 180], ...
                'Resize','off','Color',bg);
            uicontrol(warn,'Style','pushbutton','String','Close', ...
                'Position',[170 18 80 34],'Enable','on','Callback','close');
            uicontrol(warn,'Style','text','String',['The ' msg ' king is checked!'], ...
                'FontSize',16,'HorizontalAlignment','center', ...
                'Position',[20 82 380 50], ...
                'BackgroundColor',bg,'ForegroundColor',fnt);
        end

        function notifyEnd(this)
            if this.gameController.whoPlays() == 'w'
                msg='black'; bg=[1 1 1]; fnt=[0 0 0];
            else
                msg='white'; bg=[0 0 0]; fnt=[1 1 1];
            end
            warn = dialog('Name','End','Position',[500 500 460 190], ...
                'Resize','off','Color',bg);
            uicontrol(warn,'Style','pushbutton','String','Close', ...
                'Position',[250 20 90 36],'Enable','on','Callback','close all');
            uicontrol(warn,'Style','pushbutton','String','New Game', ...
                'Position',[120 20 90 36],'Enable','on', ...
                'Callback',@(~,~) run('ChessMasters'));
            uicontrol(warn,'Style','text','String',['The ' msg ' player has won!'], ...
                'FontSize',16,'HorizontalAlignment','center', ...
                'Position',[25 95 410 50], ...
                'BackgroundColor',bg,'ForegroundColor',fnt);
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
