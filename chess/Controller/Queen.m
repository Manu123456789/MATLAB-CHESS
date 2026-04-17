classdef Queen < Piece
    %Queen class
    
    properties (GetAccess = public, Constant = true)
        id = 'Q';
    end
    
    methods
        function this = Queen(chessBoardModel, color, position)
            this = this@Piece(chessBoardModel, color, position);
        end
        function boolean = IsValidMove(this,newPosition)
            boolean = Piece.isMoveOnBoard(newPosition) && (this.position(1) == newPosition(1) || this.position(2) == newPosition(2));
        end
        function path = ValidMoves(this)
            %Find objects/walls around
            path = [];
            %Obtain diagonal fields from the position of the bishop
            right_diagonal = diag(this.chessBoardModel.chessBoardMap,this.position(1)-this.position(2));
            left_diagonal = diag(fliplr(this.chessBoardModel.chessBoardMap),8-this.position(1)+1-this.position(2));
            
            %Up Right
            [y1,~] = find(right_diagonal(min(this.position(1),this.position(2)):end),2);
            if(length(y1) == 1) %only other obstacle is a wall
                distanceToWall = sum(right_diagonal(min(this.position(1),this.position(2)):end)==0);
                UpRight = [(this.position(1)+1:this.position(1)+distanceToWall)' (this.position(2)+1:this.position(2)+distanceToWall)'];
            else
                if(this.chessBoardModel.chessBoardBoxes(this.position(1)+y1(2)-y1(1),this.position(2)+y1(2)-y1(1)).button.UserData.color == this.color)
                    UpRight = [(this.position(1)+1:this.position(1)+y1(2)-y1(1)-1)' (this.position(2)+1:this.position(2)+y1(2)-y1(1)-1)'];
                else
                    UpRight = [(this.position(1)+1:this.position(1)+y1(2)-y1(1))' (this.position(2)+1:this.position(2)+y1(2)-y1(1))'];
                end
            end
            if(~isempty(UpRight))
                path = [path;UpRight];
            end
            
            %Down Left
            [y2,~] = find(right_diagonal(min(this.position(1),this.position(2)):-1:1),2);
            if(length(y2) == 1) %only other obstacle is a wall
                distanceToWall = sum(right_diagonal(min(this.position(1),this.position(2)):-1:1)==0);
                DownLeft = [(this.position(1)-1:-1:this.position(1)-distanceToWall)' (this.position(2)-1:-1:this.position(2)-distanceToWall)'];
            else
                if(this.chessBoardModel.chessBoardBoxes(this.position(1)-y2(2)+y2(1),this.position(2)-y2(2)+y2(1)).button.UserData.color == this.color)
                    DownLeft = [(this.position(1)-1:-1:this.position(1)-y2(2)+y2(1)+1)' (this.position(2)-1:-1:this.position(2)-y2(2)+y2(1)+1)'];
                else
                    DownLeft = [(this.position(1)-1:-1:this.position(1)-y2(2)+y2(1))' (this.position(2)-1:-1:this.position(2)-y2(2)+y2(1))'];
                end
            end
            if(~isempty(DownLeft))
                path = [path;DownLeft];
            end
            
            %Up Left
            [y3,~] = find(left_diagonal(end-min(8-this.position(2),this.position(1)-1):end),2);
            if(length(y3) == 1) %only other obstacle is a wall
                distanceToWall = sum(left_diagonal(end-min(8-this.position(2),this.position(1)-1):end)==0);
                UpLeft = [(this.position(1)-1:-1:this.position(1)-distanceToWall)' (this.position(2)+1:this.position(2)+distanceToWall)'];
            else
                if(this.chessBoardModel.chessBoardBoxes(this.position(1)-y3(2)+y3(1),this.position(2)+y3(2)-y3(1)).button.UserData.color == this.color)
                    UpLeft = [(this.position(1)-1:-1:this.position(1)-y3(2)+y3(1)+1)' (this.position(2)+1:this.position(2)+y3(2)-y3(1)-1)'];
                else
                    UpLeft = [(this.position(1)-1:-1:this.position(1)-y3(2)+y3(1))' (this.position(2)+1:this.position(2)+y3(2)-y3(1))'];
                end
            end
            if(~isempty(UpLeft))
                path = [path;UpLeft];
            end
            
            %Down Right
            [y4,~] = find(left_diagonal(end-min(8-this.position(2),this.position(1)-1):-1:1),2);
            if(length(y4) == 1) %only other obstacle is a wall
                distanceToWall = sum(left_diagonal(end-min(8-this.position(2),this.position(1)-1):-1:1)==0);
                DownRight = [(this.position(1)+1:this.position(1)+distanceToWall)' (this.position(2)-1:-1:this.position(2)-distanceToWall)'];
            else
                if(this.chessBoardModel.chessBoardBoxes(this.position(1)+y4(2)-y4(1),this.position(2)-y4(2)+y4(1)).button.UserData.color == this.color)
                    DownRight = [(this.position(1)+1:this.position(1)+y4(2)-y4(1)-1)' (this.position(2)-1:-1:this.position(2)-y4(2)+y4(1)+1)'];
                else
                    DownRight = [(this.position(1)+1:this.position(1)+y4(2)-y4(1))' (this.position(2)-1:-1:this.position(2)-y4(2)+y4(1))'];
                end
            end
            if(~isempty(DownRight))
                path = [path;DownRight];
            end
                  %Up
            [y1,~] = find(this.chessBoardModel.chessBoardMap(this.position(2):end,this.position(1)),2);
            if(length(y1) == 1) %only other obstacle is a wall
                Up = [this.position(1)*ones(8-this.position(2),1) (this.position(2)+1:8)'];
            else                
                if(this.chessBoardModel.chessBoardBoxes(this.position(1),this.position(2)+y1(2)-1).button.UserData.color == this.color)                   
                    Up = [this.position(1)*ones(y1(2)-2,1) (this.position(2)+1:y1(2)+this.position(2)-2)'];
                else

                    Up = [this.position(1)*ones(y1(2)-1,1) (this.position(2)+1:y1(2)+this.position(2)-1)'];
                end
            end            
            if(~isempty(Up))
                path = [path;Up];
            end
                    
            %To the right
            [~,x2] = find(this.chessBoardModel.chessBoardMap(this.position(2),this.position(1):end),2);
            if(length(x2) == 1)
                Right = [(this.position(1)+1:8)' this.position(2)*ones(8-this.position(1),1)];
            else
                if(this.chessBoardModel.chessBoardBoxes(x2(2)+this.position(1)-1,this.position(2)).button.UserData.color == this.color)
                    Right = [(this.position(1)+1:this.position(1)+x2(2)-2)' this.position(2)*ones(x2(2)-2,1)];
                else
                    Right = [(this.position(1)+1:this.position(1)+x2(2)-x2(1))' this.position(2)*ones(x2(2)-1,1)];
                end
            end
            if(~isempty(Right))
                path = [path;Right];
            end
            
           
            %To the left
            [~,x3] = find(this.chessBoardModel.chessBoardMap(this.position(2),this.position(1):-1:1),2);
            if(length(x3) == 1)                
                 Left = [(x3(1):(this.position(1))-1)' this.position(2)*ones(this.position(1)-x3(1),1)];
            else
                if(this.chessBoardModel.chessBoardBoxes(this.position(1)-x3(2)+x3(1),this.position(2)).button.UserData.color == this.color) 
                    Left = [(this.position(1)-1:-1:this.position(1)-x3(2)+x3(1)+1)' this.position(2)*ones(x3(2)-x3(1)-1,1)];
                else
                    Left = [(this.position(1)-1:-1:this.position(1)-x3(2)+x3(1))' this.position(2)*ones(x3(2)-x3(1),1)];
                end
            end
            if(~isempty(Left))
                path = [path;Left];
            end
            
                      
            %Down
            [y4,~] = find(this.chessBoardModel.chessBoardMap(this.position(2):-1:1,this.position(1)),2);
            if(length(y4) == 1) %only other obstacle is a wall
                Down = [this.position(1)*ones(this.position(2)-1,1) (1:this.position(2)-1)'];
            else                
                if(this.chessBoardModel.chessBoardBoxes(this.position(1),this.position(2)-y4(2)+y4(1)).button.UserData.color == this.color)
                    Down = [this.position(1)*ones(y4(2)-y4(1)-1,1) (this.position(2)-1:-1:this.position(2)-y4(2)+y4(1)+1)'];
                else
                   Down = [this.position(1)*ones(y4(2)-y4(1),1) (this.position(2)-1:-1:this.position(2)-y4(2)+y4(1))'];
                end
            end            
            if(~isempty(Down))
                path = [path;Down];
            end
        end
    end
end

