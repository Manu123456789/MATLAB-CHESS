classdef Knight < Piece
    
    properties (GetAccess = public, Constant = true)
        id = 'N';
    end
    
    methods (Access = public)
        function this = Knight(chessBoardModel, color, position)
            this = this@Piece(chessBoardModel, color, position);
        end
        function boolean = IsValidMove(this,newPosition)
            boolean = Piece.isMoveOnBoard(newPosition) && (abs(newPosition(2) - this.position(2)) == 1 && abs(newPosition(1) - this.position(1)) == 2 || abs(newPosition(2) - this.position(2)) == 2 && abs(newPosition(1) - this.position(1)) == 1);
        end
        
        %
        % Return coordinates of all valid moves
        %
        function path = ValidMoves(this)
            [row, col] = find(~this.chessBoardModel.chessBoardMap);
            [row1, col1] = find(this.chessBoardModel.chessBoardMap);
            Coordinates = [col row;col1 row1];
            x = [];
            y = [];
            for i = 1:size(Coordinates,1)
                if(this.IsValidMove(Coordinates(i,:)))
                    if(isempty(this.chessBoardModel.chessBoardBoxes(Coordinates(i,1),Coordinates(i,2)).button.UserData) ||~isempty(this.chessBoardModel.chessBoardBoxes(Coordinates(i,1),Coordinates(i,2)).button.UserData) && this.chessBoardModel.chessBoardBoxes(Coordinates(i,1),Coordinates(i,2)).button.UserData.color ~= this.color)
                        x = [x;Coordinates(i,1)]; %#ok
                        y = [y;Coordinates(i,2)];  %#ok
                    end
                end
            end
            path = [x y];
        end
    end
    
end