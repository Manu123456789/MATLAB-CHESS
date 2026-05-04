classdef ChessBoardModel < handle
    properties (Access = public)
        chessBoardBoxes;
        chessBoardMap
        enPassantInfo
    end
    methods
        
        function this = ChessBoardModel()
            this = paintBoxes(this);
            this.chessBoardMap = zeros(8,8);
            this.enPassantInfo = [];
        end
        
        function mapFifure(this,position,figureID)
            this.chessBoardMap(position(1),position(2)) = figureID;
        end
        
        %Set colors to the boxes
        function this = paintBoxes(this)
            boxes(1:8, 1:8) = BoardSquare(0,0);
            this.chessBoardBoxes = boxes;
            for i= 1:8
                for j= 1:8
                    if mod(j,2) == 0  && mod(i,2)==0
                        bgc = [1 204/255 153/255];
                    elseif mod(j,2) ~= 0  && mod(i,2)~=0
                        bgc = [1 204/255 153/255];
                    else
                        bgc = [224/255 224/255 224/255];
                    end
                    this.chessBoardBoxes(i,j) = BoardSquare([i j], bgc);
                end
            end
        end
    end
end
