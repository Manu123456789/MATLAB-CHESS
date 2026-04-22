classdef NetGame < handle
    % NetGame
    % -------
    % Owns the shared game file on a network drive. Responsibilities:
    %   - atomic write (temp + rename) so readers never see a torn file
    %   - stale-move detection via monotonic moveNumber
    %   - game-id binding so we don't accidentally write across games
    %   - transient read retries (SMB/NFS occasionally glitch during rename)
    %
    % Correctness model for 2-player turn-based play:
    %   * Only the side-to-move can legally produce a next state.
    %   * Before writing, we re-read and confirm the moveNumber we based
    %     our move on is still the file's current moveNumber. If the
    %     opponent somehow wrote ahead of us, we reject and ask the user
    %     to refresh.
    %   * On the same filesystem, rename(tmp -> target) is atomic on POSIX
    %     and near-atomic on Windows (MOVEFILE_REPLACE_EXISTING via MATLAB's
    %     movefile). Readers hitting the file mid-swap will either see the
    %     old inode or the new one -- not a truncated blob.
    
    properties (GetAccess = public, SetAccess = private)
        filePath           % absolute path to the shared JSON file
        myColor            % 'w' or 'b' -- which side I control
        gameId             % locks this NetGame to one specific game
        lastSeenState      % last state we loaded OR wrote
    end
    
    properties (Constant, Access = private)
        READ_RETRIES    = 3;
        READ_BACKOFF_MS = 100;
    end
    
    methods
        function this = NetGame(filePath, myColor, state)
            this.filePath      = filePath;
            this.myColor       = myColor;
            this.gameId        = state.gameId;
            this.lastSeenState = state;
        end
        
        function state = load(this)
            % Read the current state from disk. Verifies game id matches.
            state = NetGame.readJSONWithRetry(this.filePath, ...
                NetGame.READ_RETRIES, NetGame.READ_BACKOFF_MS);
            if ~strcmp(state.gameId, this.gameId)
                error('NetGame:WrongGame', ...
                    ['The file on disk belongs to a different game ' ...
                     '(id mismatch). Someone may have overwritten it.']);
            end
            this.lastSeenState = state;
        end
        
        function yes = hasOpponentMoved(this)
            % Cheap check: read the file's moveNumber and compare to what
            % we last saw. Used by the Refresh button to decide whether to
            % bother rebuilding the board.
            try
                onDisk = NetGame.readJSONWithRetry(this.filePath, ...
                    NetGame.READ_RETRIES, NetGame.READ_BACKOFF_MS);
            catch
                yes = false;
                return;
            end
            yes = (onDisk.moveNumber ~= this.lastSeenState.moveNumber) ...
                  || ~strcmp(onDisk.updatedAt, this.lastSeenState.updatedAt);
        end
        
        function save(this, state)
            % Write a new state. Requires it extends what we last saw by
            % exactly one move (optimistic concurrency via moveNumber).
            
            % Stale check: has the opponent written since our last sync?
            current = NetGame.readJSONWithRetry(this.filePath, ...
                NetGame.READ_RETRIES, NetGame.READ_BACKOFF_MS);
            if ~strcmp(current.gameId, state.gameId)
                error('NetGame:WrongGame', ...
                    'Game id on disk no longer matches this session.');
            end
            if current.moveNumber ~= this.lastSeenState.moveNumber
                error('NetGame:Stale', ...
                    ['The opponent played a move since your last sync. ' ...
                     'Please click Refresh and try again.']);
            end
            
            state.updatedAt = GameState.nowISO();
            NetGame.writeJSONAtomic(this.filePath, state);
            this.lastSeenState = state;
        end
        
        function bootstrap(this, state)
            % First write of a brand-new game. No stale check (file may
            % not exist yet). Writes atomically.
            NetGame.writeJSONAtomic(this.filePath, state);
            this.lastSeenState = state;
            this.gameId        = state.gameId;
        end
        

        function state = getCachedState(this)
            state = this.lastSeenState;
        end

        function setCachedState(this, state)
            if ~isstruct(state)
                error('NetGame:InvalidState', 'Cached state must be a struct.');
            end
            if ~isfield(state, 'gameId') || ~strcmp(state.gameId, this.gameId)
                error('NetGame:WrongGame', ...
                    'Cannot cache state for a different game id.');
            end
            this.lastSeenState = state;
        end

        function setCachedTimer(this, timerState)
            state = this.lastSeenState;
            state.timer = GameState.normalizeTimerState(timerState);
            this.lastSeenState = state;
        end

        function setCachedStatus(this, status)
            state = this.lastSeenState;
            state.status = status;
            this.lastSeenState = state;
        end

        function yes = isMyTurn(this)
            % 'check' is playable -- the checked player must respond.
            % Only terminal statuses (checkmate, timeout) block input.
            yes = ~isempty(this.lastSeenState) ...
                  && this.lastSeenState.turn == this.myColor ...
                  && (strcmp(this.lastSeenState.status, 'active') ...
                      || strcmp(this.lastSeenState.status, 'check'));
        end
    end
    
    methods (Static)
        function state = readJSONWithRetry(path, attempts, backoffMs)
            % Read + parse JSON with a few retries. Network drives can
            % briefly fail a read during an atomic rename on the other end.
            lastErr = [];
            for k = 1:attempts
                try
                    txt   = fileread(path);
                    state = GameState.fromJSON(txt);
                    return;
                catch err
                    lastErr = err;
                    pause(backoffMs/1000 * k);
                end
            end
            if isempty(lastErr)
                error('NetGame:Read', 'Failed to read %s', path);
            else
                rethrow(lastErr);
            end
        end
        
        function writeJSONAtomic(path, state)
            % Write JSON via temp file + rename. Temp lives next to the
            % target (same filesystem) so rename is atomic.
            suffix  = char('A' + mod(randi(1e6, 1, 8), 26));
            tmpPath = sprintf('%s.tmp.%s', path, suffix);
            txt     = GameState.toJSON(state);
            
            fid = fopen(tmpPath, 'w');
            if fid < 0
                error('NetGame:Write', 'Cannot open temp file: %s', tmpPath);
            end
            try
                fprintf(fid, '%s', txt);
            catch err
                fclose(fid);
                if exist(tmpPath, 'file'); delete(tmpPath); end
                rethrow(err);
            end
            fclose(fid);
            
            [ok, msg] = movefile(tmpPath, path, 'f');
            if ~ok
                if exist(tmpPath, 'file'); delete(tmpPath); end
                error('NetGame:Rename', ...
                    'Atomic rename failed (%s -> %s): %s', tmpPath, path, msg);
            end
        end
    end
end
