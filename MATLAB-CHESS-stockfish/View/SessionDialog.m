classdef SessionDialog
    % SessionDialog
    % -------------
    % Modal dialog shown before the chess board. Returns a struct describing
    % the chosen session, consumed by ChessMasters.
    %
    % Return struct fields:
    %   .mode              'local' | 'host' | 'join' | 'bot'
    %   .color             'w' | 'b'   (the human player's color)
    %   .filePath          char        (shared-game file for host/join)
    %   .stockfishPath     char        (Stockfish executable for bot mode)
    %   .stockfishOptions  struct      (UCI/search options for bot mode)
    %   .timerEnabled      logical     (host/local/bot only; join uses file value)
    %   .timerMinutes      double      (minutes per player)
    %   .cancelled         logical     (true if user closed without choosing)

    methods (Static)
        function choice = prompt()
            stockfishOptions = StockfishBot.defaultOptions();
            choice = struct('mode','', 'color','', 'filePath','', ...
                            'stockfishPath','', 'stockfishOptions',stockfishOptions, ...
                            'timerEnabled', false, 'timerMinutes', 10, ...
                            'cancelled', true);

            d = dialog('Name','New Chess Game', ...
                'Position',[500 430 520 430], ...
                'Resize','off', 'Color',[1 1 1]);

            uicontrol(d, 'Style','text', 'String','How do you want to play?', ...
                'FontSize',16, 'BackgroundColor',[1 1 1], ...
                'Position',[20 385 480 30]);

            % Mode
            uicontrol(d, 'Style','text', 'String','Mode:', ...
                'FontSize',12, 'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', 'Position',[20 345 60 20]);
            modeMenu = uicontrol(d, 'Style','popupmenu', ...
                'String',{'Local (hot-seat)', ...
                          'Host a new networked game', ...
                          'Join a networked game', ...
                          'Play against Stockfish'}, ...
                'FontSize',11, 'Position',[90 345 400 25]);

            % Color
            colorLabel = uicontrol(d, 'Style','text', 'String','Your color:', ...
                'FontSize',12, 'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', 'Position',[20 305 85 20]);
            colorMenu = uicontrol(d, 'Style','popupmenu', ...
                'String',{'White','Black'}, ...
                'FontSize',11, 'Position',[110 305 130 25]);

            % File/engine path
            pathLabel = uicontrol(d, 'Style','text', 'String','Shared game file:', ...
                'FontSize',12, 'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', 'Position',[20 265 180 20]);
            pathEdit = uicontrol(d, 'Style','edit', 'String','', ...
                'FontSize',10, 'HorizontalAlignment','left', ...
                'Position',[20 240 390 25]);
            browseButton = uicontrol(d, 'Style','pushbutton', 'String','Browse...', ...
                'FontSize',10, 'Position',[420 240 80 25], ...
                'Callback',@(~,~) SessionDialog.browse(pathEdit, modeMenu));

            % Stockfish options
            botOptionsButton = uicontrol(d, 'Style','pushbutton', ...
                'String','Stockfish Options...', 'FontSize',10, ...
                'Position',[250 305 160 25], 'Visible','off', ...
                'Callback', @onStockfishOptions);

            % Timer controls
            timerEnable = uicontrol(d, 'Style','checkbox', ...
                'String','Enable move timer', 'Value',0, ...
                'FontSize',11, 'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', ...
                'Position',[20 200 170 25]);
            uicontrol(d, 'Style','text', 'String','Time per player:', ...
                'FontSize',12, 'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', 'Position',[210 203 110 20]);
            timerMenu = uicontrol(d, 'Style','popupmenu', ...
                'String',{'1 min','3 min','5 min','10 min','15 min','20 min','30 min','45 min','60 min','90 min'}, ...
                'Value',4, ...
                'FontSize',11, 'Position',[325 200 135 25]);

            % Helper text
            helpText = uicontrol(d, 'Style','text', ...
                'String', SessionDialog.helpFor(1), ...
                'FontSize',9, 'ForegroundColor',[0.4 0.4 0.4], ...
                'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', 'Position',[20 95 480 85]);
            set(modeMenu, 'Callback', @(src,~) SessionDialog.onModeChanged(src, colorMenu, pathEdit, timerEnable, timerMenu, helpText, pathLabel, browseButton, botOptionsButton, colorLabel));
            SessionDialog.onModeChanged(modeMenu, colorMenu, pathEdit, timerEnable, timerMenu, helpText, pathLabel, browseButton, botOptionsButton, colorLabel);

            % Buttons
            uicontrol(d, 'Style','pushbutton', 'String','Start', ...
                'FontSize',11, 'Position',[330 30 80 30], ...
                'Callback', @onStart);
            uicontrol(d, 'Style','pushbutton', 'String','Cancel', ...
                'FontSize',11, 'Position',[425 30 75 30], ...
                'Callback', @(~,~) delete(d));

            uiwait(d);

            function onStockfishOptions(~,~)
                stockfishOptions = StockfishOptionsDialog.prompt(stockfishOptions);
            end

            function onStart(~,~)
                modeOpts = {'local','host','join','bot'};
                choice.mode     = modeOpts{modeMenu.Value};
                colorOpts       = {'w','b'};
                choice.color    = colorOpts{colorMenu.Value};
                rawPath         = strtrim(pathEdit.String);
                minutesList = [1 3 5 10 15 20 30 45 60 90];
                choice.timerMinutes = minutesList(timerMenu.Value);
                choice.timerEnabled = logical(timerEnable.Value);
                choice.stockfishOptions = stockfishOptions;

                if strcmp(choice.mode, 'join')
                    choice.timerEnabled = false;
                end

                if strcmp(choice.mode, 'bot')
                    choice.stockfishPath = rawPath;
                    choice.filePath = '';
                    if isempty(choice.stockfishPath)
                        errordlg('Please provide a Stockfish executable path.', ...
                                 'Missing Stockfish executable', 'modal');
                        return;
                    end
                    if exist(choice.stockfishPath, 'file') ~= 2
                        errordlg(sprintf('Stockfish executable not found:\n%s', choice.stockfishPath), ...
                                 'Missing Stockfish executable', 'modal');
                        return;
                    end
                else
                    choice.filePath = rawPath;
                    choice.stockfishPath = '';
                    if ~strcmp(choice.mode, 'local') && isempty(choice.filePath)
                        errordlg('Please provide a shared game file path.', ...
                                 'Missing file path', 'modal');
                        return;
                    end
                end

                choice.cancelled = false;
                delete(d);
            end
        end

        function onModeChanged(modeMenu, colorMenu, pathEdit, timerEnable, timerMenu, helpText, pathLabel, browseButton, botOptionsButton, colorLabel)
            modeIdx = modeMenu.Value;
            set(helpText, 'String', SessionDialog.helpFor(modeIdx));
            switch modeIdx
                case 1 % local
                    set(colorLabel, 'String', 'Your color:');
                    set(colorMenu, 'Enable', 'off');
                    set(pathLabel, 'String', 'Shared game file:');
                    set(pathEdit, 'Enable', 'off', 'String', '');
                    set(browseButton, 'Enable', 'off');
                    set(timerEnable, 'Enable', 'on');
                    set(timerMenu, 'Enable', 'on');
                    set(botOptionsButton, 'Visible', 'off');
                case 2 % host
                    set(colorLabel, 'String', 'Your color:');
                    set(colorMenu, 'Enable', 'on');
                    set(pathLabel, 'String', 'Shared game file:');
                    set(pathEdit, 'Enable', 'on');
                    set(browseButton, 'Enable', 'on');
                    set(timerEnable, 'Enable', 'on');
                    set(timerMenu, 'Enable', 'on');
                    set(botOptionsButton, 'Visible', 'off');
                case 3 % join
                    set(colorLabel, 'String', 'Your color:');
                    set(colorMenu, 'Enable', 'off');
                    set(pathLabel, 'String', 'Shared game file:');
                    set(pathEdit, 'Enable', 'on');
                    set(browseButton, 'Enable', 'on');
                    set(timerEnable, 'Enable', 'off');
                    set(timerMenu, 'Enable', 'off');
                    set(botOptionsButton, 'Visible', 'off');
                otherwise % Stockfish bot
                    set(colorLabel, 'String', 'Human color:');
                    set(colorMenu, 'Enable', 'on');
                    set(pathLabel, 'String', 'Stockfish executable:');
                    set(pathEdit, 'Enable', 'on');
                    set(browseButton, 'Enable', 'on');
                    set(timerEnable, 'Enable', 'on');
                    set(timerMenu, 'Enable', 'on');
                    set(botOptionsButton, 'Visible', 'on');
            end
        end

        function browse(pathEdit, modeMenu)
            mode = modeMenu.Value;
            if mode == 2        % Host
                [f, p] = uiputfile('*.json', 'Create new game file', 'game.json');
            elseif mode == 4    % Stockfish bot
                if ispc
                    filt = {'stockfish*.exe;*.exe', 'Stockfish executable (*.exe)'; '*.*', 'All files'};
                else
                    filt = {'stockfish*;*', 'Stockfish executable'; '*.*', 'All files'};
                end
                [f, p] = uigetfile(filt, 'Select Stockfish executable');
            else                % Join or Local
                [f, p] = uigetfile('*.json', 'Select existing game file');
            end
            if isequal(f, 0); return; end
            pathEdit.String = fullfile(p, f);
        end

        function s = helpFor(modeIdx)
            switch modeIdx
                case 1
                    s = ['Two players share one computer. File path ignored. ' ...
                         'White starts. If enabled, the move timer switches ' ...
                         'immediately after each local move.'];
                case 2
                    s = ['Creates a new shared game file. Timer settings are ' ...
                         'written into that file. After each move, the mover''s ' ...
                         'clock stops and the opponent''s starts only after a real refresh.'];
                case 3
                    s = ['Opens an existing shared game file. Color and timer ' ...
                         'settings come from that file. Your clock starts only ' ...
                         'when a refresh actually loads the opponent''s move.'];
                case 4
                    s = ['Starts a local game against a UCI Stockfish executable. ' ...
                         'Use Stockfish Options to set UCI options such as Threads, Hash, Skill Level, UCI_Elo, ' ...
                         'Syzygy options, engine files, and search limits. The engine is selected by executable path.'];
            end
        end
    end
end
