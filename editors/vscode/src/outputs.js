'use strict';

function pictureLabel(picture) {
    return picture.label || (picture.default && picture.name === 'default' ? 'Default picture' : picture.name);
}

function pictureChoices(outputs) {
    return [...outputs].sort((left, right) => Number(right.default) - Number(left.default)).map(picture => ({
        label: pictureLabel(picture),
        description: picture.default ? 'Default' : undefined,
        value: picture
    }));
}

module.exports = { pictureLabel, pictureChoices };
