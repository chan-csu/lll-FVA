function metsInLoops = findMetsInLoops(model, rxnInLoops)
if nargin < 2
    rxnInLoops = findMinNull(model);
end
metsInLoops = model.mets(any(model.S(:, any(rxnInLoops, 2)), 2));

end