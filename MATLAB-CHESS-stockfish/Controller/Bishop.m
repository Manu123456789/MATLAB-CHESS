classdef Bishop < Piece
    %
    % Public constants
    %
    properties (GetAccess = public, Constant = true)
        % Piece ID
        id = 'B';
    end
    
    %
    % Public methods
    %
    methods (Access = public)
        function this = Bishop(chessBoardModel, color, position)
            this = this@Piece(chessBoardModel, color, position);
        end
        
        function bool = IsValidMove(this,i,j)
            
        end
        
        %
        % Return coordinates of all valid moves
        %
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
         
        end
    end
end
