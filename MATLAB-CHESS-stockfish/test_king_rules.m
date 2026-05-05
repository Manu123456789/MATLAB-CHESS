function test_king_rules()
%TEST_KING_RULES Exercises the kings-cannot-touch and no-castle-out-of-check
%   rules added/verified in King.m. Run from the chess folder:
%
%       cd <repo>/chess
%       test_king_rules
%
%   The tests build a fresh ChessBoardGUI in local mode, then strip the
%   board down to a few pieces and call IsValidMove / canCastleTo
%   directly. No clicking or networking required.

    fprintf('--- test_king_rules ---\n');

    addpath(fullfile(pwd,'Model'));
    addpath(fullfile(pwd,'Controller'));
    addpath(fullfile(pwd,'View'));

    pass = 0; fail = 0;

    [pass, fail] = run(@test_kings_cannot_touch_orthogonal,  pass, fail);
    [pass, fail] = run(@test_kings_cannot_touch_diagonal,    pass, fail);
    [pass, fail] = run(@test_king_can_step_two_away,         pass, fail);
    [pass, fail] = run(@test_no_castle_while_in_check,       pass, fail);
    [pass, fail] = run(@test_no_castle_through_attack,       pass, fail);
    [pass, fail] = run(@test_no_castle_into_attack,          pass, fail);
    [pass, fail] = run(@test_castle_allowed_when_safe,       pass, fail);

    fprintf('\nresult: %d passed, %d failed\n', pass, fail);
end

% ---------- test runner ----------
function [pass, fail] = run(fn, pass, fail)
    name = func2str(fn);
    try
        fn();
        fprintf('  PASS  %s\n', name);
        pass = pass + 1;
    catch err
        fprintf('  FAIL  %s -- %s\n', name, err.message);
        fail = fail + 1;
    end
end

% ---------- scenarios ----------
function test_kings_cannot_touch_orthogonal()
    [gui, model] = freshGui();          %#ok<ASGLU>
    cleanupGui = onCleanup(@() closeGui(gui));
    clearBoard(model);
    wK = placeKing(model, 'w', [4 4]);
    bK = placeKing(model, 'b', [6 4]); %#ok<NASGU>
    % white king at d4, black king at f4. White king to e4 would be
    % adjacent to black king. Must be rejected.
    assertFalse(wK.IsValidMove([5 4]), 'white K should not step next to black K');
    % e3 is also adjacent to f4 -- rejected.
    assertFalse(wK.IsValidMove([5 3]), 'white K should not step next to black K (diag)');
    % d3 is two squares from f4 -- allowed.
    assertTrue(wK.IsValidMove([4 3]),  'white K should be free to step away');
end

function test_kings_cannot_touch_diagonal()
    [gui, model] = freshGui(); cleanupGui = onCleanup(@() closeGui(gui)); %#ok<NASGU>
    clearBoard(model);
    wK = placeKing(model, 'w', [4 4]);
    placeKing(model, 'b', [6 6]);
    % e5 is diagonally adjacent to f6 -- rejected.
    assertFalse(wK.IsValidMove([5 5]), 'white K should not move diagonally next to black K');
end

function test_king_can_step_two_away()
    [gui, model] = freshGui(); cleanupGui = onCleanup(@() closeGui(gui)); %#ok<NASGU>
    clearBoard(model);
    wK = placeKing(model, 'w', [4 4]);
    placeKing(model, 'b', [7 4]);
    assertTrue(wK.IsValidMove([5 4]),  'white K may step toward black K when still two squares away');
end

function test_no_castle_while_in_check()
    [gui, model] = freshGui(); cleanupGui = onCleanup(@() closeGui(gui)); %#ok<NASGU>
    clearBoard(model);
    wK = placeKing(model, 'w', [5 1]);
    placeRook(model, 'w', [8 1]);
    placeKing(model, 'b', [5 8]);
    placeRook(model, 'b', [5 5]);   % black rook delivers check on e-file
    assertFalse(wK.IsValidMove([7 1]), 'cannot castle kingside out of check');
end

function test_no_castle_through_attack()
    [gui, model] = freshGui(); cleanupGui = onCleanup(@() closeGui(gui)); %#ok<NASGU>
    clearBoard(model);
    wK = placeKing(model, 'w', [5 1]);
    placeRook(model, 'w', [8 1]);
    placeKing(model, 'b', [5 8]);
    placeRook(model, 'b', [6 5]);   % attacks f-file, including f1 (the middle square)
    assertFalse(wK.IsValidMove([7 1]), 'cannot castle through attacked f1');
end

function test_no_castle_into_attack()
    [gui, model] = freshGui(); cleanupGui = onCleanup(@() closeGui(gui)); %#ok<NASGU>
    clearBoard(model);
    wK = placeKing(model, 'w', [5 1]);
    placeRook(model, 'w', [8 1]);
    placeKing(model, 'b', [5 8]);
    placeRook(model, 'b', [7 5]);   % attacks g-file, including g1 (destination)
    assertFalse(wK.IsValidMove([7 1]), 'cannot castle onto attacked g1');
end

function test_castle_allowed_when_safe()
    [gui, model] = freshGui(); cleanupGui = onCleanup(@() closeGui(gui)); %#ok<NASGU>
    clearBoard(model);
    wK = placeKing(model, 'w', [5 1]);
    placeRook(model, 'w', [8 1]);
    placeKing(model, 'b', [5 8]);
    assertTrue(wK.IsValidMove([7 1]), 'should be able to castle kingside in a clean position');
end

% ---------- helpers ----------
function [gui, model] = freshGui()
    % ChessMasters('local') skips the session dialog and wires up the
    % model + controller + GUI exactly the way local-mode play does. We
    % need the GUI because ChessBoardGUI is what attaches uicontrol
    % buttons to each BoardSquare; King.IsValidMove reads UserData off
    % those buttons.
    cm = ChessMasters('local');
    gui = cm.chessBoardGUI;
    model = cm.chessBoardModel;
end

function closeGui(gui)
    try
        if ~isempty(gui) && isprop(gui,'figureHandle') && ishandle(gui.figureHandle)
            delete(gui.figureHandle);
        end
    catch
    end
end

function clearBoard(model)
    for f = 1:8
        for r = 1:8
            btn = model.chessBoardBoxes(f,r).button;
            set(btn, 'CData', [], 'UserData', '');
            model.chessBoardMap(r,f) = 0;
        end
    end
end

function k = placeKing(model, color, pos)
    k = King(model, color, pos);
    set(model.chessBoardBoxes(pos(1),pos(2)).button, 'UserData', k);
    model.chessBoardMap(pos(2),pos(1)) = double('K');
end

function r = placeRook(model, color, pos)
    r = Rook(model, color, pos);
    set(model.chessBoardBoxes(pos(1),pos(2)).button, 'UserData', r);
    model.chessBoardMap(pos(2),pos(1)) = double('R');
end

function assertTrue(cond, msg)
    if ~cond
        error('assertTrue failed: %s', msg);
    end
end

function assertFalse(cond, msg)
    if cond
        error('assertFalse failed: %s', msg);
    end
end
