-- Specs for the spinner frame catalog (dadbod-ui.spinners), adapted from
-- cli-spinners. Guards the two sets the UI actually depends on: `dots` for
-- connection loading and `dots12` (the braille wave moved out of dbout) for the
-- query result-buffer spinner.

local spinners = require('dadbod-ui.spinners')

describe('spinners catalog', function()
  it('provides the dots set used for connection loading', function()
    assert.is_table(spinners.dots)
    assert.equals(10, #spinners.dots)
    assert.equals('⠋', spinners.dots[1])
    assert.equals('⠏', spinners.dots[10])
  end)

  it('keeps the dots12 braille set (56 frames) for the query result spinner', function()
    assert.equals(56, #spinners.dots12)
    assert.equals('⢀⠀', spinners.dots12[1])
    assert.equals('⠀⡀', spinners.dots12[56])
  end)

  it('every catalog entry is a non-empty list of string frames', function()
    for name, frames in pairs(spinners) do
      assert.is_true(#frames > 0, name .. ' has frames')
      for _, frame in ipairs(frames) do
        assert.is_string(frame)
      end
    end
  end)
end)
