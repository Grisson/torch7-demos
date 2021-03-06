#!/usr/bin/env torch
------------------------------------------------------------
--
-- CNN face detector, based on convolutional network nets
--
-- original: Clement Farabet
-- E. Culurciello, A. Dundar, A. Canziani
-- Tue Mar 11 10:52:58 EDT 2014
--
------------------------------------------------------------

require 'pl'
require 'qt'
require 'qtwidget'
require 'qtuiloader'
require 'camera'
require 'image'
require 'nnx'
print '==> processing options'

opt = lapp[[
   -c, --camidx   (default 0)             camera index: /dev/videoIDX
   -n, --network  (default 'model.net')   path to networkimage.
   -t, --threads  (default 8)             number of threads
       --HD       (default true)          high resolution camera
]]

torch.setdefaulttensortype('torch.FloatTensor')
torch.setnumthreads(opt.threads)

-- blob parser in FFI (almost as fast as pure C!):
-- does not work anymore after some Torch changes.... need fix!@
function parseFFI(pin, iH, iW, threshold, blobs, scale)
  --loop over pixels
  for y=0, iH-1 do
     for x=0, iW-1 do
        if (pin[iW*y+x] > threshold) then
          entry = {}
          entry[1] = x
          entry[2] = y
          entry[3] = scale
          table.insert(blobs,entry)
      end
    end
  end
end


function prune(detections)
  local pruned = {}

  local index = 1
   for i,detect in ipairs(detections) do
     local duplicate = 0
     for j, prune in ipairs(pruned) do
       -- if two detections left top corners are in close proximity discard one
       -- 70 is a proximity threshold can be changed
       if (torch.abs(prune.x-detect.x)+torch.abs(prune.y-detect.y)<70) then
        duplicate = 1
       end
     end

     if duplicate == 0 then
      pruned[index] = {x=detect.x, y=detect.y, w=detect.w, h=detect.h}
      index = index+1
     end
   end

   return pruned
end

-- load pre-trained network from disk
network1 = torch.load(opt.network, 'ascii') --load a network split in two: network and classifier
network = network1.modules[1] -- split network
network1.modules[2].modules[3] = nil -- remove logsoftmax
classifier1 = network1.modules[2] -- split and reconstruct classifier

network.modules[6] = nn.SpatialClassifier(classifier1)
network_fov = 32
network_sub = 4


print('Neural Network used: \n', network) -- print final network

-- setup camera
local GUI
if opt.HD then
   camera = image.Camera(opt.camidx,640,360)
   GUI = 'HDg.ui'
else
   camera = image.Camera(opt.camidx)
   GUI = 'g.ui'
end

-- process input at multiple scales
scales = {0.3, 0.24, 0.192, 0.15, 0.12, 0.1}

-- use a pyramid packer/unpacker
require 'PyramidPacker'
require 'PyramidUnPacker'
packer = nn.PyramidPacker(network, scales)
unpacker = nn.PyramidUnPacker(network)

-- setup GUI (external UI file)
if not win or not widget then
   widget = qtuiloader.load(GUI)
   win = qt.QtLuaPainter(widget.frame)
end

-- profiler
p = xlua.Profiler()

-- Use local normalization:
-- we need to do this step here as the face dataset is contrast normalized
-- and so the demo needs to do it also:
local neighborhood = image.gaussian1D(5)
local normalization = nn.SpatialContrastiveNormalization(1, neighborhood, 1):float()

-- process function
function process()
   -- (1) grab frame
   frame = camera:forward()

   -- (2) transform it into Y space and global normalize:
   frameY = image.rgb2y(frame)
   -- global normalization:
   local fmean = frameY:mean()
   local fstd = frameY:std()
   frameY:add(-fmean)
   frameY:div(fstd)

    -- (3) create multiscale pyramid
   pyramid, coordinates = packer:forward(frameY)
   -- local contrast normalization:
   pyramid = normalization:forward(pyramid)

   -- (4) run pre-trained network on it
   multiscale = network:forward(pyramid)
   -- (5) unpack pyramid
   distributions = unpacker:forward(multiscale, coordinates)
   -- (6) parse distributions to extract blob centroids
   threshold = widget.verticalSlider.value/100 -1.5


   rawresults = {}
   for i,distribution in ipairs(distributions) do
      local pdist = torch.data(distribution[1]:contiguous())
      parseFFI(pdist, distribution[1]:size(1), distribution[1]:size(2), threshold, rawresults, scales[i])
   end

   -- (7) clean up results
   detections = {}
   for i,res in ipairs(rawresults) do
      local scale = res[3]
      local x = res[1]*network_sub/scale
      local y = res[2]*network_sub/scale
      local w = network_fov/scale
      local h = network_fov/scale
      detections[i] = {x=x, y=y, w=w, h=h}
   end
   detections = prune(detections)
end

-- display function
function display()
   win:gbegin()
   win:showpage()
   -- (1) display input image + pyramid
   image.display{image=frame, win=win}
   -- (2) overlay bounding boxes for each detection
   for i,detect in ipairs(detections) do
      win:setcolor(1,0,0)
      win:rectangle(detect.x, detect.y, detect.w, detect.h)
      win:stroke()
      win:setfont(qt.QFont{serif=false,italic=false,size=16})
      win:moveto(detect.x, detect.y-1)
      win:show('face')
   end
   win:gend()
end

-- setup gui
timer = qt.QTimer()
timer.interval = 1
timer.singleShot = true
qt.connect(timer,
           'timeout()',
           function()
              p:start('full loop','fps')
              p:start('prediction','fps')
              process()
              p:lap('prediction')
              p:start('display','fps')
              display()
              p:lap('display')
              timer:start()
              p:lap('full loop')
              --p:printAll()
           end)
widget.windowTitle = 'e-Lab Face Detector'
widget:show()
timer:start()
