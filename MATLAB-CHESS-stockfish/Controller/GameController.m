classdef GameController < handle
    properties (GetAccess = public, SetAccess = private)
        chessBoardModel;
        round;
    end
    methods
        function this = GameController(chessBoardModel)
            this.chessBoardModel = chessBoardModel;
            this.round = 1;
        end
        
        function playRound(this)
            this.round = this.round + 1;
        end
        
        function setRound(this, r)
            % Set the round counter directly. Used by GameState.applyToModel
            % when rebuilding the game from a serialized snapshot, and by
            % the GUI to roll back after a failed network write.
            this.round = r;
        end
        
        function s = gameStatus(this) %#ok<MANU>
            % Coarse status string for the GUI. The networked path keeps
            % its own 'status' field in GameState. In local mode we simply
            % return 'active'; mate is announced by notifyEnd during the
            % move that triggered it.
            s = 'active';
        end
        %Check if any of the pieces of the king can stop the check either
        %by capturing the figure or blocking the path
        function boolean = blockThePathOrTakeIt(this,piece)
            if(piece.color == 'w')
                color = 'b';
            else
                color = 'w';
            end
            [y,x] = find(this.chessBoardModel.chessBoardMap ~= 75 & this.chessBoardModel.chessBoardMap ~= 0);
            linearindex = sub2ind(size(this.chessBoardModel.chessBoardBoxes), x, y);
            boxes = this.chessBoardModel.chessBoardBoxes(linearindex);
            buttons = [boxes.button];
            pieces = [buttons.UserData];
            colors = [pieces.color];
            paths = [];
            %Find pieces of opposite color
            indexes = find(colors == color);
            for i=1:length(indexes)
                paths = [paths; pieces(indexes(i)).ValidMoves]; %#ok
            end
            
            king = this.findKing(color);
            if((piece.id == 'N' || piece.id == 'P') && ~isempty(find(ismember(piece.position,paths,'rows'),1)))
                path = piece.position;
            elseif(piece.position(2) > king.position(2))
                %Rook or Queen
                if(piece.position(1) == king.position(1))
                    path = [piece.position(1)*ones(piece.position(2)-king.position(2)+1,1) (piece.position(2):-1:king.position(2))'];
                    %Bishop or Queen
                elseif(piece.position(1) > king.position(1))
                    path = [(king.position(1)+1:piece.position(1))' (king.position(2)+1:piece.position(2))'];
                else
                    path = [(king.position(1)-1:-1:piece.position(1))' (king.position(2)+1:piece.position(2))'];
                end
            elseif(piece.position(2) < king.position(2))
                %Rook or Queen
                if(piece.position(1) == king.position(1))
                    path = [piece.position(1)*ones(king.position(2)-piece.position(2)+1,1) (king.position(2):-1:piece.position(2))'];
                    %Bishop or Queen
                elseif(piece.position(1) > king.position(1))
                    path = [(piece.position(1)-1:-1:king.position(1))'    (king.position(2)-1:-1:piece.position(2))'];
                else
                    path = [(king.position(1)+1:piece.position(1))' (king.position(2)+1:piece.position(2))'];
                end
                %Bishop or Queen
            elseif(piece.position(2) == king.position(2))
                if(king.position(1) > piece.position(1))
                    path = [(king.position(1)-1:-1:piece.position(1))' piece.position(2)*ones(king.position(1)-piece.position(1),1)];
                else
                    path = [(king.position(1)+1:piece.position(1))' piece.position(2)*ones(piece.position(1)-king.position(1),1)];
                end
            end
            if(isempty(find(ismember(path,paths,'rows'),1)))
                boolean = 1;
            else
                boolean = 0;
            end
        end
        
        function boolean = checkPromotion(~,pawn)
            boolean = pawn.position(2) == 1 || pawn.position(2) == 8;
        end
        
        function boolean = checkCheckMate(this)
            % Legacy wrapper kept for compatibility. True mate means the
            % side to move is currently in check and has no legal escape.
            boolean = this.isKingInCheck(this.whoPlays) && ...
                ~this.hasAnyLegalMove(this.whoPlays);
        end

        function boolean = isKingInCheck(this, color)
            boolean = ~this.checkNoCoverCheck(color);
        end

        function boolean = hasAnyLegalMove(this, color)
            boolean = false;
            [y,x] = find(this.chessBoardModel.chessBoardMap ~= 0);
            for k = 1:numel(x)
                piece = this.chessBoardModel.chessBoardBoxes(x(k), y(k)).button.UserData;
                if isempty(piece) || ischar(piece) || piece.color ~= color
                    continue;
                end
                moves = piece.ValidMoves;
                for m = 1:size(moves,1)
                    if this.isLegalMoveForColor(piece, moves(m,:))
                        boolean = true;
                        return;
                    end
                end
            end
        end

        function boolean = isLegalMoveForColor(this, piece, newPosition)
            boolean = false;
            color = piece.color;
            src = piece.position;
            srcBtn = this.chessBoardModel.chessBoardBoxes(src(1), src(2)).button;
            dstBtn = this.chessBoardModel.chessBoardBoxes(newPosition(1), newPosition(2)).button;
            dstPieceBefore = dstBtn.UserData;
            srcUsedBefore = piece.used;
            prevMapSrc = this.chessBoardModel.chessBoardMap(src(2), src(1));
            prevMapDst = this.chessBoardModel.chessBoardMap(newPosition(2), newPosition(1));

            isEnPassant = false;
            victimPos = [];
            victimBtn = [];
            victimPieceBefore = [];
            prevMapVictim = [];
            info = [];
            if isprop(this.chessBoardModel, 'enPassantInfo')
                info = this.chessBoardModel.enPassantInfo;
            end
            if piece.id == 'P' && abs(newPosition(1) - src(1)) == 1 && isempty(dstPieceBefore) && ...
                    ~isempty(info) && isstruct(info) && isfield(info,'target') && isfield(info,'victim') && ...
                    ~isempty(info.target) && ~isempty(info.victim) && isequal(info.target, newPosition)
                victimPos = info.victim;
                victimBtn = this.chessBoardModel.chessBoardBoxes(victimPos(1), victimPos(2)).button;
                victimPieceBefore = victimBtn.UserData;
                prevMapVictim = this.chessBoardModel.chessBoardMap(victimPos(2), victimPos(1));
                isEnPassant = ~isempty(victimPieceBefore) && ~ischar(victimPieceBefore);
            end

            isCastle = false;
            rook = [];
            rookFrom = [];
            rookTo = [];
            rookBtnFrom = [];
            rookBtnTo = [];
            rookUsedBefore = [];
            rookDstPieceBefore = [];
            prevMapRookFrom = [];
            prevMapRookTo = [];
            if piece.id == 'K' && abs(newPosition(1) - src(1)) == 2
                [rook, rookFrom, rookTo] = piece.getCastleRook(newPosition);
                if ~isempty(rook)
                    rookBtnFrom = this.chessBoardModel.chessBoardBoxes(rookFrom(1), rookFrom(2)).button;
                    rookBtnTo   = this.chessBoardModel.chessBoardBoxes(rookTo(1), rookTo(2)).button;
                    rookUsedBefore = rook.used;
                    rookDstPieceBefore = rookBtnTo.UserData;
                    prevMapRookFrom = this.chessBoardModel.chessBoardMap(rookFrom(2), rookFrom(1));
                    prevMapRookTo   = this.chessBoardModel.chessBoardMap(rookTo(2), rookTo(1));
                    isCastle = true;
                end
            end

            cleanupObj = onCleanup(@() restoreState());

            piece.movePiece(newPosition);
            set(dstBtn, 'UserData', piece);
            set(srcBtn, 'UserData', '');
            if isEnPassant
                set(victimBtn, 'UserData', '');
                this.chessBoardModel.chessBoardMap(victimPos(2), victimPos(1)) = 0;
            end
            if isCastle
                rook.movePiece(rookTo);
                set(rookBtnTo, 'UserData', rook);
                set(rookBtnFrom, 'UserData', '');
            end

            boolean = this.checkNoCoverCheck(color);
            clear cleanupObj;

            function restoreState()
                try
                    piece.position = src;
                    piece.used = srcUsedBefore;
                    this.chessBoardModel.chessBoardMap(src(2), src(1)) = prevMapSrc;
                    this.chessBoardModel.chessBoardMap(newPosition(2), newPosition(1)) = prevMapDst;
                    set(srcBtn, 'UserData', piece);
                    set(dstBtn, 'UserData', dstPieceBefore);
                    if isEnPassant
                        set(victimBtn, 'UserData', victimPieceBefore);
                        this.chessBoardModel.chessBoardMap(victimPos(2), victimPos(1)) = prevMapVictim;
                    end
                    if isCastle
                        rook.position = rookFrom;
                        rook.used = rookUsedBefore;
                        this.chessBoardModel.chessBoardMap(rookFrom(2), rookFrom(1)) = prevMapRookFrom;
                        this.chessBoardModel.chessBoardMap(rookTo(2), rookTo(1)) = prevMapRookTo;
                        set(rookBtnFrom, 'UserData', rook);
                        set(rookBtnTo, 'UserData', rookDstPieceBefore);
                    end
                catch
                end
            end
        end
        
        function color = whoPlays(this)
            if(mod(this.round,2) == 0)
                color = 'b';
            else
                color = 'w';
            end
        end
        
        function king = findKing(this,color)
            [y,x] = find(this.chessBoardModel.chessBoardMap == 75);
            if(this.chessBoardModel.chessBoardBoxes(x(1),y(1)).button.UserData.color == color)
                king = this.chessBoardModel.chessBoardBoxes(x(1),y(1)).button.UserData;
            else
                king = this.chessBoardModel.chessBoardBoxes(x(2),y(2)).button.UserData;
            end
        end
        function placePieces(this)
            %Pawn placement
            for i = 1:8
                set(this.chessBoardModel.chessBoardBoxes(i,2).button,'CData',ChessBoardGUI.createRGB('resources/PW.png'),...
                    'UserData', Pawn(this.chessBoardModel,'w',[i 2]),'Enable','on');
                this.chessBoardModel.mapFifure([2 i],Pawn.id);
                
                set(this.chessBoardModel.chessBoardBoxes(i,7).button,'CData',ChessBoardGUI.createRGB('resources/PB.png'),...
                    'UserData', Pawn(this.chessBoardModel,'b',[i 7]),'Enable','on');
                this.chessBoardModel.mapFifure([7 i],Pawn.id);
            end
            %Rook placement
            set(this.chessBoardModel.chessBoardBoxes(1,1).button,'CData',ChessBoardGUI.createRGB('resources/RW.png'),...
                'UserData', Rook(this.chessBoardModel,'w',[1 1]),'Enable','on');
            this.chessBoardModel.mapFifure([1 1], Rook.id);
            
            set(this.chessBoardModel.chessBoardBoxes(8,1).button,'CData',ChessBoardGUI.createRGB('resources/RW.png'),...
                'UserData', Rook(this.chessBoardModel,'w',[8 1]),'Enable','on');
            this.chessBoardModel.mapFifure([1 8], Rook.id);
            
            set(this.chessBoardModel.chessBoardBoxes(1,8).button,'CData',ChessBoardGUI.createRGB('resources/RB.png'),...
                'UserData', Rook(this.chessBoardModel,'b',[1 8]),'Enable','on');
            this.chessBoardModel.mapFifure([8 1], Rook.id);
            
            set(this.chessBoardModel.chessBoardBoxes(8,8).button,'CData',ChessBoardGUI.createRGB('resources/RB.png'),...
                'UserData', Rook(this.chessBoardModel,'b',[8 8]),'Enable','on');
            this.chessBoardModel.mapFifure([8 8], Rook.id);
            
            %Knight placement
            set(this.chessBoardModel.chessBoardBoxes(2,1).button,'CData',ChessBoardGUI.createRGB('resources/NW.png'),...
                'UserData', Knight(this.chessBoardModel,'w',[2 1]),'Enable','on');
            this.chessBoardModel.mapFifure([1 2], Knight.id);
            
            set(this.chessBoardModel.chessBoardBoxes(7,1).button,'CData',ChessBoardGUI.createRGB('resources/NW.png'),...
                'UserData', Knight(this.chessBoardModel,'w',[7 1]),'Enable','on');
            this.chessBoardModel.mapFifure([1 7], Knight.id);
            
            set(this.chessBoardModel.chessBoardBoxes(2,8).button,'CData',ChessBoardGUI.createRGB('resources/NB.png'),...
                'UserData', Knight(this.chessBoardModel,'b',[2 8]),'Enable','on');
            this.chessBoardModel.mapFifure([8 2], Knight.id);
            
            set(this.chessBoardModel.chessBoardBoxes(7,8).button,'CData',ChessBoardGUI.createRGB('resources/NB.png'),...
                'UserData', Knight(this.chessBoardModel,'b',[7 8]),'Enable','on');
            this.chessBoardModel.mapFifure([8 7], Knight.id);
            
            %Bishop placement
            set(this.chessBoardModel.chessBoardBoxes(3,1).button,'CData',ChessBoardGUI.createRGB('resources/BW.png'),...
                'UserData', Bishop(this.chessBoardModel,'w',[3 1]),'Enable','on');
            this.chessBoardModel.mapFifure([1 3], Bishop.id);
            
            set(this.chessBoardModel.chessBoardBoxes(6,1).button,'CData',ChessBoardGUI.createRGB('resources/BW.png'),...
                'UserData', Bishop(this.chessBoardModel,'w',[6 1]),'Enable','on');
            this.chessBoardModel.mapFifure([1 6], Bishop.id);
            
            set(this.chessBoardModel.chessBoardBoxes(3,8).button,'CData',ChessBoardGUI.createRGB('resources/BB.png'),...
                'UserData', Bishop(this.chessBoardModel,'b',[3 8]),'Enable','on');
            this.chessBoardModel.mapFifure([8 3], Bishop.id);
            
            set(this.chessBoardModel.chessBoardBoxes(6,8).button,'CData',ChessBoardGUI.createRGB('resources/BB.png'),...
                'UserData', Bishop(this.chessBoardModel,'b',[6 8]),'Enable','on');
            this.chessBoardModel.mapFifure([8 6], Bishop.id);
            
            %Queen placement
            set(this.chessBoardModel.chessBoardBoxes(4,1).button,'CData',ChessBoardGUI.createRGB('resources/QW.png'),...
                'UserData', Queen(this.chessBoardModel,'w',[4 1]),'Enable','on');
            this.chessBoardModel.mapFifure([1 4], Queen.id);
            
            set(this.chessBoardModel.chessBoardBoxes(4,8).button,'CData',ChessBoardGUI.createRGB('resources/QB.png'),...
                'UserData', Queen(this.chessBoardModel,'b',[4 8]),'Enable','on');
            this.chessBoardModel.mapFifure([8 4], Queen.id);
            
            %King placement
            set(this.chessBoardModel.chessBoardBoxes(5,1).button,'CData',ChessBoardGUI.createRGB('resources/KW.png'),...
                'UserData', King(this.chessBoardModel,'w',[5 1]),'Enable','on');
            this.chessBoardModel.mapFifure([1 5], King.id);
            
            set(this.chessBoardModel.chessBoardBoxes(5,8).button,'CData',ChessBoardGUI.createRGB('resources/KB.png'),...
                'UserData', King(this.chessBoardModel,'b',[5 8]),'Enable','on');
            this.chessBoardModel.mapFifure([8 5], King.id);
        end
        
        function boolean = checkNoCoverCheck(this,color)
            king = this.findKing(color);
            boolean = (this.chessBoardModel.chessBoardBoxes(king.position(1),king.position(2)).button.UserData.checkForPossibleCheckBeforeMovingKing(king.position));
        end
        
        function boolean = checkCheck(this,piece)
            if(piece.color == 'w')
                color = 'b';
            else
                color = 'w';
            end
            king = this.findKing(color);
            %The king is in the future path of the moved figure = check
            if(~isempty(piece.ValidMoves))
                boolean = (~isempty(find(ismember(piece.ValidMoves,king.position,'rows'),1)));
            else
                boolean = 0;
            end
        end
    end
end
