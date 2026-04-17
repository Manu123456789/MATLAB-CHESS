classdef Pawn < Piece
    
    properties (GetAccess = public, Constant = true)
        id = 'P';
    end
    methods (Access = public)
        function this = Pawn(chessBoardModel, color, position)
            this = this@Piece(chessBoardModel, color, position);
        end
        %
        % Return coordinates of all valid moves
        %
        function path = ValidMoves(this)
            path = [];
            if(this.color == 'w')
                %Moving Up
                [y,~] = find(this.chessBoardModel.chessBoardMap(this.position(2):min(this.position(2)+2,8),this.position(1)),2);
                if(length(y)==1) %%there is no obstacle
                    if(this.used)
                        path = [this.position(1)*ones(1,1) (this.position(2)+1:this.position(2)+1)'];
                    else
                        path = [this.position(1)*ones(2,1) (this.position(2)+1:this.position(2)+2)'];
                    end
                elseif(length(y)==1 && (this.position(2)+1)>=8)%wall ready for promotion
                    path = [this.position(1)*ones(8-this.position(2),1) (this.position(2)+1:8)'];
                else
                    path = [this.position(1)*ones(y(2)-y(1)-1,1) (this.position(2)+1:this.position(2)+y(2)-y(1)-1)'];
                end
                if(this.position(2)~=8)
                %Diagonal move
                if(this.position(1)==1)
                    search =  this.chessBoardModel.chessBoardBoxes(this.position(1)+1,this.position(2)+1);
                elseif(this.position(1)==8)
                    search =  this.chessBoardModel.chessBoardBoxes(this.position(1)-1 ,this.position(2)+1);
                else
                    search =  this.chessBoardModel.chessBoardBoxes([this.position(1)-1 this.position(1)+1],this.position(2)+1);
                end
                for i = 1:numel(search)
                    if(~isempty(search(i).button.UserData) && ~ischar(search(i).button.UserData) && search(i).button.UserData.color == 'b')
                        path = [path; search(i).button.UserData.position]; %#ok
                    end
                end
                end
            else
                %Moving Down
                [y,~] = find(this.chessBoardModel.chessBoardMap(this.position(2):-1:max(this.position(2)-2,1),this.position(1)),2);
                if(length(y)==1) %%there is no obstacle
                    if(this.used)
                        path = [this.position(1)*ones(1,1) (this.position(2)-1:-1:this.position(2)-1)'];
                    else
                        path = [this.position(1)*ones(2,1) (this.position(2)-1:-1:this.position(2)-2)'];
                    end
                elseif((this.position(2)-1)>1)%wall ready for promotion
                    path = [this.position(1)*ones(y(2)-y(1)-1,1) (this.position(2)-1:-1:this.position(2)-y(2)+y(1)+1)'];
                end
                if(this.position(2)~=1)
                %Diagonal move
                if(this.position(1)==1)
                    search =  this.chessBoardModel.chessBoardBoxes(this.position(1)+1,this.position(2)-1);
                elseif(this.position(1)==8)
                    search =  this.chessBoardModel.chessBoardBoxes(this.position(1)-1 ,this.position(2)-1);
                elseif(this.position(2)~=1)
                    search =  this.chessBoardModel.chessBoardBoxes(this.position(1)-1,this.position(2)-1);
                    search = [search this.chessBoardModel.chessBoardBoxes(this.position(1)+1,this.position(2)-1)];
                end
                for i = 1:size(search,2)
                    if(~isempty(search(i).button.UserData) && ~ischar(search(i).button.UserData) && search(i).button.UserData.color == 'w')
                        path = [path; search(i).button.UserData.position]; %#ok
                    end
                end
                end
            end
            path = this.appendEnPassantMoves(path);
        end
    end

    methods (Access = private)
        function path = appendEnPassantMoves(this, path)
            info = [];
            if isprop(this.chessBoardModel, 'enPassantInfo')
                info = this.chessBoardModel.enPassantInfo;
            end
            if isempty(info) || ~isstruct(info)
                return;
            end
            if ~isfield(info, 'target') || ~isfield(info, 'victim') || ~isfield(info, 'capturerColor')
                return;
            end
            if isempty(info.target) || isempty(info.victim)
                return;
            end
            if this.color ~= info.capturerColor
                return;
            end
            target = info.target;
            victim = info.victim;
            if abs(this.position(1) - victim(1)) ~= 1 || this.position(2) ~= victim(2)
                return;
            end
            targetBtn = this.chessBoardModel.chessBoardBoxes(target(1), target(2)).button;
            victimBtn = this.chessBoardModel.chessBoardBoxes(victim(1), victim(2)).button;
            if isempty(targetBtn) || isempty(victimBtn)
                return;
            end
            targetPiece = targetBtn.UserData;
            victimPiece = victimBtn.UserData;
            if (~isempty(targetPiece) && ~ischar(targetPiece))
                return;
            end
            if isempty(victimPiece) || ischar(victimPiece) || victimPiece.id ~= 'P' || victimPiece.color == this.color
                return;
            end
            path = [path; target]; %#ok<AGROW>
        end
    end
end