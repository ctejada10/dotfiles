// Grid layout for Amethyst, layout key "grid". Amethyst finds it by its file
// name in ~/Library/Application Support/Amethyst/Layouts/ when it starts.
//
// Fills cells left to right, top to bottom:
//   1 window  → full screen
//   2 windows → two halves
//   3 windows → two on top, one full-width below
//   4 windows → 2×2
//   5+        → grows to 3×2, 3×3 … ; a short last row stretches to fill the width
function layout() {
    return {
        name: "Grid",
        getFrameAssignments: (windows, screenFrame) => {
            const n = windows.length;
            if (n === 0) return {};
            const cols = Math.max(1, Math.ceil(Math.sqrt(n)));
            const rows = Math.ceil(n / cols);
            const cellHeight = screenFrame.height / rows;

            return windows.reduce((frames, window, index) => {
                const row = Math.floor(index / cols);
                const inRow = row === rows - 1 ? n - row * cols : cols;
                const col = index - row * cols;
                const cellWidth = screenFrame.width / inRow;
                const x = Math.round(screenFrame.x + col * cellWidth);
                const y = Math.round(screenFrame.y + row * cellHeight);
                frames[window.id] = {
                    x: x,
                    y: y,
                    width: Math.round(screenFrame.x + (col + 1) * cellWidth) - x,
                    height: Math.round(screenFrame.y + (row + 1) * cellHeight) - y
                };
                return frames;
            }, {});
        }
    };
}
