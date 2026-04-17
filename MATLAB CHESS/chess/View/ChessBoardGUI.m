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
        timerWhiteText
        timerBlackText
        moveTimerObj             = []
        localTimerState          = []
        timerExpiredLocal        = false

        % Selection state ------------------------------------------------
        selectedFile             = []     % 1..8 or []
        selectedRank             = []     % 1..8 or []
        selectedOrigBg           = []     % background color before selection
        highlightSnapshot        = {}     % cell array of snapshot structs

        % Cached dot image (generated once) ------------------------------
        dotCData

        % Semaphore: set during applyToModel to suppress click handling
        suppressInput            = false
    end

    properties (Constant, Access = private)
        COLOR_SELECTED   = [1 1 0.4]      % selected piece background (pale yellow)
        COLOR_CAPTURE    = [1 0.72 0.72]  % capture target background (pale red)
        COLOR_LASTMOVE   = [0.76 0.9 0.6] % from/to flash after opponent moves
        TILE_PX          = 100
        BOARD_ORIGIN_X   = 20
        BOARD_ORIGIN_Y   = 40
        TOP_BAR_HEIGHT   = 60
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
            this.syncClockAfterBoardLoad([], this.currentStateStruct(), true);
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
                'FontSize',14, 'HorizontalAlignment','left', ...
                'BackgroundColor',[1 1 1], ...
                'Position',[this.BOARD_ORIGIN_X topBarY 600 30]);
            this.refreshButton = uicontrol(h, 'Style','pushbutton', ...
                'String','Refresh', 'FontSize',12, ...
                'Position',[890 topBarY 120 30], ...
                'Enable',   this.refreshEnableFlag(), ...
                'Callback', @(~,~) this.onRefreshClicked());
            this.timerWhiteText = uicontrol(h, 'Style','text', 'String','White  --:--', ...
                'FontSize',12, 'HorizontalAlignment','right', ...
                'BackgroundColor',[1 1 1], 'Position',[620 topBarY 120 30]);
            this.timerBlackText = uicontrol(h, 'Style','text', 'String','Black  --:--', ...
                'FontSize',12, 'HorizontalAlignment','right', ...
                'BackgroundColor',[1 1 1], 'Position',[750 topBarY 120 30]);

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
            if ~isempty(this.netGame) && ~this.netGame.isMyTurn(); return; end
            if ~strcmp(this.gameController.gameStatus(), 'active'); return; end
            if this.isClockExpired(); return; end

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
            if movedPiece.id == 'P' && this.gameController.checkPromotion(movedPiece)
                this.promote(movedPiece);
            end

            % Would this move leave our king in check? Roll back if so.
            if movedPiece.id ~= 'K' && ~this.gameController.checkNoCoverCheck(movedPiece.color)
                this.rollbackMove(srcFile, srcRank, dstFile, dstRank, ...
                    movedPiece, dstPieceBefore, srcPictureBefore, dstPictureBefore, castleInfo, enPassantInfo, prevEnPassantInfo, srcPieceUsedBefore);
                this.notifyNoCoverCheck();
                return;
            end

            this.chessBoardModel.enPassantInfo = this.computeNextEnPassantInfo(srcPiece, srcFile, srcRank, dstFile, dstRank);
            nextTimerState = this.timerStateAfterCompletedMove(prevTimerState, srcPiece.color);
            this.stopMoveTimer();
            this.applyTimerStateToCurrentContext(nextTimerState);
            this.gameController.playRound();

            dstPiece = this.chessBoardModel.chessBoardBoxes(dstFile, dstRank).button.UserData;
            opponentColor = 'w'; if dstPiece.color == 'w'; opponentColor = 'b'; end

            checkState = '';
            if this.gameController.checkCheck(dstPiece) || ~this.gameController.checkNoCoverCheck(opponentColor)
                if this.gameController.checkCheckMate() && this.gameController.blockThePathOrTakeIt(movedPiece)
                    checkState = 'checkmate';
                else
                    checkState = 'check';
                end
            end

            % Persist to disk in networked mode
            if ~isempty(this.netGame)
                state = this.buildStateAfterMove(srcFile, srcRank, dstFile, dstRank, ...
                    movedPiece, wasCapture, checkState, castleInfo, enPassantInfo, nextTimerState);
                try
                    this.netGame.save(state);
                catch err
                    this.rollbackMove(srcFile, srcRank, dstFile, dstRank, ...
                        movedPiece, dstPieceBefore, srcPictureBefore, dstPictureBefore, castleInfo, enPassantInfo, prevEnPassantInfo, srcPieceUsedBefore);
                    this.applyTimerStateToCurrentContext(prevTimerState);
                    this.resumeTimerIfNeeded();
                    this.gameController.setRound(this.gameController.round - 1);
                    errordlg(err.message, 'Network write failed', 'modal');
                    return;
                end
            end

            if strcmp(checkState, 'checkmate')
                this.notifyEnd();
            elseif strcmp(checkState, 'check')
                this.notifyCheck();
            end
            if isempty(this.netGame)
                this.startTimerForColorIfEnabled(this.gameController.whoPlays(), false);
            end
            this.updateStatusBar();
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
            if isempty(epi) || ~isstruct(epi) || ~isfield(epi, 'target') || ~isfield(epi, 'victim')
                return;
            end
            if isempty(epi.target) || isempty(epi.victim)
                return;
            end
            if any(epi.target ~= [dstFile dstRank]) || piece.color ~= epi.capturerColor
                return;
            end
            info.isEnPassant = true;
            info.capturedFile = epi.victim(1);
            info.capturedRank = epi.victim(2);
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
        % Networked refresh
        % ---------------------------------------------------------------
        function onRefreshClicked(this)
            if isempty(this.netGame); return; end
            this.clearSelection();
            prevState = this.netGame.lastSeenState;
            try
                state = this.netGame.load();
            catch err
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
            this.updateStatusBar();
        end

        function unsuppressInput(this)
            this.suppressInput = false;
        end

        function redrawAfterStateLoad(this, state)
            if nargin < 2 || isempty(state); return; end
            this.applyTimerStateToCurrentContext(state.timer);
            this.refreshTimerLabels();
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
                    msg = sprintf('You are %s  --  waiting for opponent  (move %d, click Refresh)', ...
                        myStr, s.moveNumber);
                end
                if ~strcmp(s.status, 'active')
                    msg = sprintf('%s  |  %s', msg, upper(s.status));
                end
            end
            set(this.statusText, 'String', msg);
            this.refreshTimerLabels();
        end

        function flag = refreshEnableFlag(this)
            if isempty(this.netGame); flag = 'off'; else; flag = 'on'; end
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
                this.netGame.lastSeenState.timer = timerState;
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
                return;
            end
            timerState.running = true;
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
            if ~timerState.enabled || ~timerState.running || ~isempty(timerState.expiredColor)
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
                if ~isempty(this.netGame)
                    this.netGame.lastSeenState.timer = timerState;
                    this.netGame.lastSeenState.status = 'timeout';
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
            warn = dialog('Name','Check','Position',[500 500 300 150], ...
                'Resize','off','Color',bg);
            uicontrol(warn,'Style','pushbutton','String','Close', ...
                'Position',[110 20 80 30],'Enable','on','Callback','close');
            uicontrol(warn,'Style','text','String',['The ' msg ' king is checked!'], ...
                'FontSize',22,'Position',[0 70 300 30], ...
                'BackgroundColor',bg,'ForegroundColor',fnt);
        end

        function notifyEnd(this)
            if this.gameController.whoPlays() == 'w'
                msg='black'; bg=[1 1 1]; fnt=[0 0 0];
            else
                msg='white'; bg=[0 0 0]; fnt=[1 1 1];
            end
            warn = dialog('Name','End','Position',[500 500 300 150], ...
                'Resize','off','Color',bg);
            uicontrol(warn,'Style','pushbutton','String','Close', ...
                'Position',[140 20 80 30],'Enable','on','Callback','close all');
            uicontrol(warn,'Style','pushbutton','String','New Game', ...
                'Position',[60 20 80 30],'Enable','on', ...
                'Callback',@(~,~) run('ChessMasters'));
            uicontrol(warn,'Style','text','String',['The ' msg ' player has won!'], ...
                'FontSize',22,'Position',[0 70 300 30], ...
                'BackgroundColor',bg,'ForegroundColor',fnt);
        end

        function notifyNoCoverCheck(this)
            if this.gameController.whoPlays() == 'w'
                msg='white'; bg=[1 1 1]; fnt=[0 0 0];
            else
                msg='black'; bg=[0 0 0]; fnt=[1 1 1];
            end
            warn = dialog('Name','Check','Position',[500 500 600 150], ...
                'Resize','off','Color',bg);
            uicontrol(warn,'Style','pushbutton','String','Close', ...
                'Position',[260 20 80 30],'Enable','on','Callback','close');
            uicontrol(warn,'Style','text', ...
                'String',['Invalid move! The ' msg ' king would be checked!'], ...
                'FontSize',22,'Position',[0 70 600 30], ...
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
