classdef BoardSquare < handle
    properties
        position;
        color;
        button
        clicked
    end
    methods
        function this = BoardSquare(position,color)
            this.clicked = false;
            this.position = position;
            this.color = color;
        end
         function setButton(this, button)
            this.button = button;
        end
    end
end