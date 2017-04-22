SHELL=/bin/bash

# read variable settings from separate config file
include config.mk

# Download OSM QA tiles
data/osm/planet.mbtiles:
	mkdir -p $(dir $@)
	curl https://s3.amazonaws.com/mapbox/osm-qa-tiles/latest.planet.mbtiles.gz | gunzip > $@

data/osm/%.mbtiles:
	mkdir -p $(dir $@)
	curl https://s3.amazonaws.com/mapbox/osm-qa-tiles/latest.country/$(notdir $@).gz | gunzip > $@

.PHONY: download-osm-tiles
download-osm-tiles: data/osm/$(QA_TILES).mbtiles
	echo "Downloading $(QA_TILES) extract."

# Make a list of all the tiles within BBOX
data/all_tiles.txt:
	if [[ $(DATA_TILES) == mbtiles* ]] ; then \
		tippecanoe-enumerate $(subst mbtiles://./,,$(DATA_TILES)) | node lib/read-sample.js --bbox='$(BBOX)' > $@ ; \
		else echo "$(DATA_TILES) is not an mbtiles source: you will need to create data/all_tiles.txt manually." && exit 1 ; \
		fi

# Make a random sample from all_tiles.txt of TRAIN_SIZE tiles, possibly
# 'overzooming' them to zoom=ZOOM_LEVEL
data/sample.txt: data/all_tiles.txt
	./sample $^ $(TRAIN_SIZE) $(ZOOM_LEVEL) > $@

# Rasterize the data tiles to bitmaps where each pixel is colored according to
# the class defined in CLASSES
# (no class / background => black)
data/labels/color: data/sample.txt
	mkdir -p $@
	cp $(CLASSES) data/classes.json
	cat data/sample.txt | \
	  parallel --pipe --block 10K './rasterize-labels $(DATA_TILES) $(CLASSES) $@'

data/labels/label-counts.txt: data/labels/color data/sample.txt
	cat data/sample.txt | \
		parallel --pipe --block 10K --group './label-counts $(CLASSES) data/labels/color' > $@
	# Also generate label-stats.csv
	cat data/labels/label-counts.txt | ./label-stats > data/labels/label-stats.csv

# Once we've generated label bitmaps, we can make a version of the original sample
# filtered to tiles with the ratio (pixels with non-background label)/(total pixels)
# above the LABEL_RATIO threshold
data/sample-filtered.txt: data/labels/label-counts.txt
	cat $^ | node lib/read-sample.js --label-ratio $(LABEL_RATIO) > $@

data/labels/grayscale: data/sample-filtered.txt
	mkdir -p $@
	cat $^ | \
		cut -d' ' -f2,3,4 | sed 's/ /-/g' | \
		parallel 'cat data/labels/color/{}.png | ./palette-to-grayscale $(CLASSES) > $@/{}.png'

data/images: data/sample-filtered.txt
	mkdir -p $@
	cat data/sample-filtered.txt | ./download-images $(IMAGE_TILES) $@

.PHONY: remove-bad-images
remove-bad-images: data/sample-filtered.txt
	# Delete satellite images that are too black or too white
	# Afterwards, update the text file so we don't look for these later
	ls data/images/* | \
	  ./remove-bad-images

.PHONY: prune-labels
prune-labels: data/sample-filtered.txt
	# Iterate through label images, and delete any for which there is no
	# corresponding satellite image
	cat data/sample-filtered.txt | \
		cut -d' ' -f2,3,4 | sed 's/ /-/g' > data/labels/color/include.txt
	find data/labels/color -name *.png | grep -Fvf data/labels/color/include.txt | xargs rm
	rm data/labels/color/include.txt
	touch data/labels/label-counts.txt
	touch data/sample-filtered.txt

# Create image pair text files, this will drop references for images which aren't found
data/image-pairs.txt: data/sample-filtered.txt data/labels/grayscale data/images
	cat data/sample-filtered.txt | \
		./list-image-pairs --basedir $$(cd data && pwd -P) \
			--labels labels/grayscale \
			--images images > $@

# Make train & val lists, with 80% of data -> train, 20% -> val
data/train.txt: data/image-pairs.txt
	split -l $$(($$(cat data/image-pairs.txt | wc -l) * 4 / 5)) data/image-pairs.txt
	mv xaa $@
	mv xab data/val.txt

.PHONY: all
all: data/train.txt data/val.txt

.PHONY: clean-labels clean-images clean
clean-labels:
	rm -rf data/labels
clean-images:
	rm -rf data/images
clean: clean-images clean-labels
	rm data/sample.txt
