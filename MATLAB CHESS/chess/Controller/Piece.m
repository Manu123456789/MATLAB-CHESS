classdef Piece <  handle & matlab.mixin.Heterogeneous

    properties (SetAccess = private, GetAccess = public)
        chessBoardModel;
        color;
    end
    
    properties (SetAccess = public, GetAccess = public)
        position;
        path;
        used;
    end
    
    %
    % Abstract public constants
    %
    properties (Abstract = true, GetAccess = public, Constant = true)
        id;                         % Piece ID number
    end
    
    %
    % Public methods
    %
    methods (Access = public)
        %
        % Constructor
        %
        function this = Piece(chessBoardModel,color,position)
            % Save piece information
            this.chessBoardModel = chessBoardModel;
            this.color = color;
            this.position = position;
            this.used = false;
        end
        %Move piece virtually 
        function this = movePiece(this, newPosition)
            if(~this.used)
                this.used = true;
            end
            this.chessBoardModel.chessBoardMap(this.position(2),this.position(1)) = 0;
            this.position = newPosition;
            this.chessBoardModel.chessBoardMap(this.position(2),this.position(1)) = this.id;
        end
    end
    methods (Access = public, Abstract = true)
        path = ValidMoves(this);
    end
    methods(Access = public, Static = true)
        function  boolean = isMoveOnBoard(newPosition)
            boolean = newPosition(1) < 9 && newPosition(1) > 0 && newPosition(2) < 9 && newPosition(2) > 0;
        end
    end
end
