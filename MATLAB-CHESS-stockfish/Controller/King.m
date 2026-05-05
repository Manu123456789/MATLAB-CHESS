classdef King < Piece
    
    properties (GetAccess = public, Constant = true)
        id = 'K';
    end
    
    methods (Access = public)
        function this = King(chessBoardModel, color, position)
            this = this@Piece(chessBoardModel, color, position);
        end
        
        function boolean = IsValidMove(this,newPosition)
            if this.isCastleMove(newPosition)
                boolean = this.canCastleTo(newPosition);
            else
                boolean = Piece.isMoveOnBoard(newPosition) && ...
                    checkForPossibleCheckBeforeMovingKing(this,newPosition) && ...
                    freeOrEnemy(this,newPosition) && ...
                    abs(newPosition(2) - this.position(2)) < 2 && ...
                    abs(newPosition(1) - this.position(1)) < 2;
            end
        end
        
        function boolean = freeOrEnemy(this,newPosition)
            boolean = isempty(this.chessBoardModel.chessBoardBoxes(newPosition(1),newPosition(2)).button.UserData) || ~isempty(this.chessBoardModel.chessBoardBoxes(newPosition(1),newPosition(2)).button.UserData) && this.chessBoardModel.chessBoardBoxes(newPosition(1),newPosition(2)).button.UserData.color ~= this.color;
        end

        function boolean = isCastleMove(this, newPosition)
            boolean = Piece.isMoveOnBoard(newPosition) && ...
                newPosition(2) == this.position(2) && ...
                abs(newPosition(1) - this.position(1)) == 2;
        end

        function boolean = canCastleTo(this, newPosition)
            boolean = false;
            if ~this.isCastleMove(newPosition) || this.used
                return;
            end
            if ~isempty(this.chessBoardModel.chessBoardBoxes(newPosition(1),newPosition(2)).button.UserData)
                return;
            end

            [rook, rookFrom, ~] = this.getCastleRook(newPosition);
            if isempty(rook) || rook.used
                return;
            end

            if ~this.areSquaresEmptyBetween(this.position(1), rookFrom(1), this.position(2))
                return;
            end

            step = sign(newPosition(1) - this.position(1));
            middleSquare = this.position + [step 0];

            % FIDE castling rules concerning check: (1) the king must
            % not currently be in check, (2) the king must not pass
            % through an attacked square, and (3) the king must not
            % land on an attacked square. Each call below uses
            % checkForPossibleCheckBeforeMovingKing, which now also
            % rejects squares adjacent to the enemy king.
            if ~this.checkForPossibleCheckBeforeMovingKing(this.position)
                return;
            end
            if ~this.checkForPossibleCheckBeforeMovingKing(middleSquare)
                return;
            end
            if ~this.checkForPossibleCheckBeforeMovingKing(newPosition)
                return;
            end

            boolean = true;
        end

        function boolean = areSquaresEmptyBetween(this, startFile, endFile, rank)
            boolean = true;
            for file = (min(startFile, endFile) + 1):(max(startFile, endFile) - 1)
                occupant = this.chessBoardModel.chessBoardBoxes(file, rank).button.UserData;
                if ~isempty(occupant)
                    boolean = false;
                    return;
                end
            end
        end

        function [rook, rookFrom, rookTo] = getCastleRook(this, newPosition)
            rank = this.position(2);
            if newPosition(1) > this.position(1)
                rookFrom = [8 rank];
                rookTo   = [6 rank];
            else
                rookFrom = [1 rank];
                rookTo   = [4 rank];
            end
            rook = this.chessBoardModel.chessBoardBoxes(rookFrom(1), rookFrom(2)).button.UserData;
            if isempty(rook) || ischar(rook) || rook.id ~= 'R' || rook.color ~= this.color
                rook = [];
            end
        end
        %Check if the king can move there and if not exclude it from the
        %path
        function boolean = checkOnBlackKing(this, newPosition)
            paths = [];
            %Virtually move king & store the previous info
            previousID = this.chessBoardModel.chessBoardMap(newPosition(2),newPosition(1));
            previousPiece=this.chessBoardModel.chessBoardBoxes(newPosition(1),newPosition(2)).button.UserData;
            previousPosition = this.position;
            set(this.chessBoardModel.chessBoardBoxes(this.position(1),this.position(2)).button,'UserData','');
            set(this.chessBoardModel.chessBoardBoxes(newPosition(1),newPosition(2)).button,'UserData',this);
            this.chessBoardModel.chessBoardMap(this.position(2),this.position(1)) = 0;
            this.chessBoardModel.chessBoardMap(newPosition(2),newPosition(1)) = this.id;
            this.position = newPosition;
            
            % If ValidMoves throws below, onCleanup guarantees we still
            % restore the board to its prior state before unwinding.
            restorer = onCleanup(@() King.restoreAfterVirtualMove( ...
                this, previousPosition, newPosition, previousID, previousPiece));
            
            %Find all pieces and their positions
            [y,x] = find(this.chessBoardModel.chessBoardMap ~= 75 & this.chessBoardModel.chessBoardMap ~= 0);
            linearindex = sub2ind(size(this.chessBoardModel.chessBoardBoxes), x, y);
            boxes = this.chessBoardModel.chessBoardBoxes(linearindex);
            buttons = [boxes.button];
            pieces = [buttons.UserData];
            colors = [pieces.color];
            
            %Find white pieces
            indexes = find(colors == 'w');
            
            for i=1:length(indexes)
                paths = [paths; pieces(indexes(i)).ValidMoves]; %#ok
            end
            
            clear restorer;   % triggers restore via onCleanup
            
            if(~isempty(paths))
                boolean = isempty(find(ismember(paths,newPosition,'rows'),1));
            else
                boolean = 1;
            end
        end
        function boolean = checkOnWhiteKing(this, newPosition)
            paths = [];
            %Virtually move king & store the previous info
            previousID = this.chessBoardModel.chessBoardMap(newPosition(2),newPosition(1));
            previousPiece=this.chessBoardModel.chessBoardBoxes(newPosition(1),newPosition(2)).button.UserData;
            previousPosition = this.position;
            set(this.chessBoardModel.chessBoardBoxes(this.position(1),this.position(2)).button,'UserData','');
            set(this.chessBoardModel.chessBoardBoxes(newPosition(1),newPosition(2)).button,'UserData',this);
            this.chessBoardModel.chessBoardMap(this.position(2),this.position(1)) = 0;
            this.chessBoardModel.chessBoardMap(newPosition(2),newPosition(1)) = this.id;
            this.position = newPosition;
            
            restorer = onCleanup(@() King.restoreAfterVirtualMove( ...
                this, previousPosition, newPosition, previousID, previousPiece));
            
            %Find all pieces and their positions
            [y,x] = find(this.chessBoardModel.chessBoardMap ~= 75 & this.chessBoardModel.chessBoardMap ~= 0);
            linearindex = sub2ind(size(this.chessBoardModel.chessBoardBoxes), x, y);
            boxes = this.chessBoardModel.chessBoardBoxes(linearindex);
            buttons = [boxes.button];
            pieces = [buttons.UserData];
            colors = [pieces.color];
            
            %Find white pieces
            indexes = find(colors == 'b');
            
            for i=1:length(indexes)            
                paths = [paths; pieces(indexes(i)).ValidMoves]; %#ok
            end
            
            clear restorer;
            
            if(~isempty(paths))
                boolean = isempty(find(ismember(paths,newPosition,'rows'),1));             
            else
                boolean = 1;
            end
        end
        function boolean = checkForPossibleCheckBeforeMovingKing(this,newPosition)
            % Fail fast if newPosition is on or adjacent to the enemy king.
            % checkOn{White,Black}King iterates pieces with
            % chessBoardMap ~= 75, which excludes BOTH kings (75 == 'K').
            % That filter exists to prevent the mutual recursion that
            % would otherwise occur when the enemy king's IsValidMove
            % calls back into this method, but it also hides enemy-king
            % attacks from the path iteration. The two-kings-can-never-
            % touch rule is therefore enforced explicitly here, which
            % covers regular king moves AND the start/middle/end squares
            % checked by canCastleTo.
            if this.isAdjacentToOrOnEnemyKing(newPosition)
                boolean = false;
                return;
            end
            if (this.color == 'w')
                boolean = this.checkOnWhiteKing(newPosition);
            else
                boolean = this.checkOnBlackKing(newPosition);
            end
        end

        function boolean = isAdjacentToOrOnEnemyKing(this, square)
            % True if `square` lies within Chebyshev distance 1 of the
            % enemy king (i.e. the enemy king's square or any of its 8
            % neighbours). Used to enforce the rule that two kings can
            % never legally occupy adjacent squares, since a king
            % attacks all eight of its surrounding squares.
            boolean = false;
            if this.color == 'w'
                enemyColor = 'b';
            else
                enemyColor = 'w';
            end
            % chessBoardMap stores piece IDs as their ASCII codes; 'K'
            % is 75. find returns (row, col) = (rank, file), so we
            % swap into (file, rank) for chessBoardBoxes lookups.
            [yk, xk] = find(this.chessBoardModel.chessBoardMap == 75);
            for k = 1:numel(xk)
                candidate = this.chessBoardModel.chessBoardBoxes(xk(k), yk(k)).button.UserData;
                if isempty(candidate) || ischar(candidate)
                    continue;
                end
                if candidate.color == enemyColor && ...
                        abs(candidate.position(1) - square(1)) <= 1 && ...
                        abs(candidate.position(2) - square(2)) <= 1
                    boolean = true;
                    return;
                end
            end
        end
        %
        % Return coordinates of all valid moves
        %
        function path = ValidMoves(this)
            %Find objects/walls around
            path = [];
            if(this.IsValidMove(this.position+1))
                path = [path;this.position+1];
            end
            if (this.IsValidMove(this.position-1))
                path = [path;this.position-1];
            end
            if (this.IsValidMove(this.position+[1 -1]))
   
                path = [path;this.position+[1 -1]];
            end
            if (this.IsValidMove(this.position+[-1 1]))
               
                path = [path;this.position+[-1 1]];
            end
            if (this.IsValidMove(this.position+[1 0]))
          
                path = [path;this.position+[1 0]];
            end
            if (this.IsValidMove(this.position+[-1 0]))
                 
                path = [path;this.position+[-1 0]];
            end
            if (this.IsValidMove(this.position+[0 1]))
       
                path = [path;this.position+[0 1]];
            end
            if (this.IsValidMove(this.position+[0 -1]))
  
                path = [path;this.position+[0 -1]];
            end
            if (this.IsValidMove(this.position+[2 0]))
                path = [path;this.position+[2 0]];
            end
            if (this.IsValidMove(this.position+[-2 0]))
                path = [path;this.position+[-2 0]];
            end
        end
        
    end
    
    methods (Static, Access = public)
        function restoreAfterVirtualMove(king, previousPosition, newPosition, previousID, previousPiece)
            % Undo the virtual king move that checkOnWhiteKing /
            % checkOnBlackKing applied. Called via onCleanup so it runs
            % whether the enclosing function returns normally or errors.
            try
                king.position = previousPosition;
                king.chessBoardModel.chessBoardMap(previousPosition(2), previousPosition(1)) = king.id;
                king.chessBoardModel.chessBoardMap(newPosition(2),      newPosition(1))      = previousID;
                set(king.chessBoardModel.chessBoardBoxes(previousPosition(1), previousPosition(2)).button, ...
                    'UserData', king);
                set(king.chessBoardModel.chessBoardBoxes(newPosition(1), newPosition(2)).button, ...
                    'UserData', previousPiece);
            catch
                % Nothing sensible to do if restore itself fails (e.g. the
                % figure was closed mid-analysis). Swallow so we don't
                % mask the original error.
            end
        end
    end
end
