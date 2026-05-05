classdef ChessMasters
    % ChessMasters
    % ------------
    % Entry point. Presents the session dialog, then wires up the model,
    % controller, NetGame (for networked sessions), and GUI.
    
    properties (Access = public)
        chessBoardModel
        chessBoardGUI
        gameController
        netGame
    end
    
    methods (Access = public)
        function this = ChessMasters(shortcut)
            clc
            try; close all; catch; end
            addpath Model View Controller
            
            if nargin >= 1 && strcmp(shortcut, 'local')
                choice = struct('mode','local','color','w','filePath','', ...
                    'timerEnabled', false, 'timerMinutes', 10, 'cancelled', false);
            else
                choice = SessionDialog.prompt();
            end
            if choice.cancelled
                return;
            end
            
            switch choice.mode
                case 'local'
                    this = this.startLocal(choice.timerEnabled, choice.timerMinutes);
                case 'host'
                    this = this.startHost(choice.color, choice.filePath, ...
                        choice.timerEnabled, choice.timerMinutes);
                case 'join'
                    this = this.startJoin(choice.filePath);
            end
        end
    end
    
    methods (Access = private)
        function this = startLocal(this, timerEnabled, timerMinutes)
            this.chessBoardModel = ChessBoardModel();
            this.gameController  = GameController(this.chessBoardModel);
            timerState = GameState.makeTimerState(timerEnabled, timerMinutes);
            this.chessBoardGUI   = ChessBoardGUI(this.chessBoardModel, this.gameController, [], 'w', timerState);
        end
        
        function this = startHost(this, color, path, timerEnabled, timerMinutes)
            state            = GameState.initial(color, timerEnabled, timerMinutes);
            this.chessBoardModel = ChessBoardModel();
            this.gameController  = GameController(this.chessBoardModel);
            this.netGame     = NetGame(path, color, state);
            try
                this.netGame.bootstrap(state);
            catch err
                errordlg(sprintf('Could not create game file:\n%s\n\n%s', ...
                    path, err.message), 'Host failed', 'modal');
                return;
            end
            this.chessBoardGUI = ChessBoardGUI(this.chessBoardModel, ...
                this.gameController, this.netGame, color);
        end
        
        function this = startJoin(this, path)
            try
                txt   = fileread(path);
                state = GameState.fromJSON(txt);
            catch err
                errordlg(sprintf('Could not open game file:\n%s\n\n%s', ...
                    path, err.message), 'Join failed', 'modal');
                return;
            end
            if ~isfield(state, 'hostColor') || isempty(state.hostColor)
                errordlg('Game file is missing hostColor field.', 'Join failed', 'modal');
                return;
            end
            myColor = 'b'; if state.hostColor == 'b'; myColor = 'w'; end
            this.chessBoardModel = ChessBoardModel();
            this.gameController  = GameController(this.chessBoardModel);
            this.netGame         = NetGame(path, myColor, state);
            this.chessBoardGUI   = ChessBoardGUI(this.chessBoardModel, ...
                this.gameController, this.netGame, myColor);
        end
    end
end
