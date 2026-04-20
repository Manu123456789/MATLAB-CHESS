classdef SessionDialog
    % SessionDialog
    % -------------
    % Modal dialog shown before the chess board. Returns a struct describing
    % the chosen session, consumed by ChessMasters.
    %
    % Return struct fields:
    %   .mode          'local' | 'host' | 'join'
    %   .color         'w' | 'b'           (the color this player will control)
    %   .filePath      char                 (where to read/write the shared game)
    %   .timerEnabled  logical              (host/local only; join uses file value)
    %   .timerMinutes  double               (minutes per player)
    %   .cancelled     logical              (true if user closed without choosing)
    
    methods (Static)
        function choice = prompt()
            choice = struct('mode','', 'color','', 'filePath','', ...
                            'timerEnabled', false, 'timerMinutes', 10, ...
                            'cancelled', true);
            
            d = dialog('Name','New Chess Game', ...
                'Position',[500 500 480 360], ...
                'Resize','off', 'Color',[1 1 1]);
            
            uicontrol(d, 'Style','text', 'String','How do you want to play?', ...
                'FontSize',16, 'BackgroundColor',[1 1 1], ...
                'Position',[20 315 440 30]);
            
            % Mode
            uicontrol(d, 'Style','text', 'String','Mode:', ...
                'FontSize',12, 'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', 'Position',[20 280 60 20]);
            modeMenu = uicontrol(d, 'Style','popupmenu', ...
                'String',{'Local (hot-seat)','Host a new networked game','Join a networked game'}, ...
                'FontSize',11, 'Position',[90 280 370 25]);
            
            % Color
            uicontrol(d, 'Style','text', 'String','Your color:', ...
                'FontSize',12, 'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', 'Position',[20 240 80 20]);
            colorMenu = uicontrol(d, 'Style','popupmenu', ...
                'String',{'White','Black'}, ...
                'FontSize',11, 'Position',[110 240 130 25]);
            
            % File path
            uicontrol(d, 'Style','text', 'String','Shared game file:', ...
                'FontSize',12, 'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', 'Position',[20 200 140 20]);
            pathEdit = uicontrol(d, 'Style','edit', 'String','', ...
                'FontSize',10, 'HorizontalAlignment','left', ...
                'Position',[20 175 360 25]);
            uicontrol(d, 'Style','pushbutton', 'String','Browse...', ...
                'FontSize',10, 'Position',[390 175 70 25], ...
                'Callback',@(~,~) SessionDialog.browse(pathEdit, modeMenu));
            
            % Timer controls
            timerEnable = uicontrol(d, 'Style','checkbox', ...
                'String','Enable move timer', 'Value',0, ...
                'FontSize',11, 'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', ...
                'Position',[20 135 170 25]);
            uicontrol(d, 'Style','text', 'String','Time per player:', ...
                'FontSize',12, 'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', 'Position',[210 138 110 20]);
            timerMenu = uicontrol(d, 'Style','popupmenu', ...
                'String',{'5 min','10 min','15 min','20 min','30 min','45 min','60 min','90 min'}, ...
                'Value',2, ...
                'FontSize',11, 'Position',[325 135 135 25]);
            
            % Helper text
            helpText = uicontrol(d, 'Style','text', ...
                'String', SessionDialog.helpFor(1), ...
                'FontSize',9, 'ForegroundColor',[0.4 0.4 0.4], ...
                'BackgroundColor',[1 1 1], ...
                'HorizontalAlignment','left', 'Position',[20 75 440 45]);
            set(modeMenu, 'Callback', @(src,~) SessionDialog.onModeChanged(src, colorMenu, pathEdit, timerEnable, timerMenu, helpText));
            SessionDialog.onModeChanged(modeMenu, colorMenu, pathEdit, timerEnable, timerMenu, helpText);
            
            % Buttons
            uicontrol(d, 'Style','pushbutton', 'String','Start', ...
                'FontSize',11, 'Position',[300 20 80 30], ...
                'Callback', @onStart);
            uicontrol(d, 'Style','pushbutton', 'String','Cancel', ...
                'FontSize',11, 'Position',[390 20 70 30], ...
                'Callback', @(~,~) delete(d));
            
            uiwait(d);
            
            function onStart(~,~)
                modeOpts = {'local','host','join'};
                choice.mode     = modeOpts{modeMenu.Value};
                colorOpts       = {'w','b'};
                choice.color    = colorOpts{colorMenu.Value};
                choice.filePath = strtrim(pathEdit.String);
                minutesList = [5 10 15 20 30 45 60 90];
                choice.timerMinutes = minutesList(timerMenu.Value);
                choice.timerEnabled = logical(timerEnable.Value);
                if strcmp(choice.mode, 'join')
                    choice.timerEnabled = false;
                end
                if ~strcmp(choice.mode, 'local') && isempty(choice.filePath)
                    errordlg('Please provide a shared game file path.', ...
                             'Missing file path', 'modal');
                    return;
                end
                choice.cancelled = false;
                delete(d);
            end
        end
        
        function onModeChanged(modeMenu, colorMenu, pathEdit, timerEnable, timerMenu, helpText)
            modeIdx = modeMenu.Value;
            set(helpText, 'String', SessionDialog.helpFor(modeIdx));
            switch modeIdx
                case 1 % local
                    set(colorMenu, 'Enable', 'off');
                    set(pathEdit, 'Enable', 'off');
                    set(timerEnable, 'Enable', 'on');
                    set(timerMenu, 'Enable', 'on');
                case 2 % host
                    set(colorMenu, 'Enable', 'on');
                    set(pathEdit, 'Enable', 'on');
                    set(timerEnable, 'Enable', 'on');
                    set(timerMenu, 'Enable', 'on');
                otherwise % join
                    set(colorMenu, 'Enable', 'off');
                    set(pathEdit, 'Enable', 'on');
                    set(timerEnable, 'Enable', 'off');
                    set(timerMenu, 'Enable', 'off');
            end
        end
        
        function browse(pathEdit, modeMenu)
            mode = modeMenu.Value;
            if mode == 2        % Host
                [f, p] = uiputfile('*.json', 'Create new game file', 'game.json');
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
            end
        end
    end
end
