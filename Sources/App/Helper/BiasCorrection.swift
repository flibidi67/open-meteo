

import Foundation

/// QM and QDM based on https://link.springer.com/article/10.1007/s00382-020-05447-4
/// Loosly based on https://github.com/btschwertfeger/BiasAdjustCXX/blob/master/src/CMethods.cxx
/// Question: calculate CDF for each month? sliding doy? -> Distrubution based bias control does ot require this?
struct BiasCorrection {
    
    enum ChangeType {
        /// Correct offset. E.g. temperature
        case absoluteChage
        
        /// Scale. E.g. Precipitation
        case relativeChange
    }
    
    static func quantileMapping(reference: ArraySlice<Float>, control: ArraySlice<Float>, forecast: ArraySlice<Float>, type: ChangeType) -> [Float] {
        // calculate CDF
        let binsRefernce = calculateBins(reference, min: type == .relativeChange ? 0 : nil)
        let binsControl = calculateBins(control, min: type == .relativeChange ? 0 : nil)
        let cdfRefernce = calculateCdf(reference, bins: binsRefernce)
        let cdfControl = calculateCdf(control, bins: binsControl)
        
        // Apply
        switch type {
        case .absoluteChage:
            return forecast.map {
                let qm = interpolate(binsControl, cdfControl, x: $0, extrapolate: false)
                return interpolate(cdfRefernce, binsRefernce, x: qm, extrapolate: false)
            }
        case .relativeChange:
            return forecast.map {
                let qm = max(interpolate(binsControl, cdfControl, x: $0, extrapolate: true), 0)
                return max(interpolate(cdfRefernce, binsRefernce, x: qm, extrapolate: true), 0)
            }
        }
    }
    
    static func quantileDeltaMapping(reference: ArraySlice<Float>, control: ArraySlice<Float>, forecast: ArraySlice<Float>, type: ChangeType) -> [Float] {
        // calculate CDF
        let binsControl = calculateBins(control, min: type == .relativeChange ? 0 : nil)
        let binsRefernce = binsControl// calculateBins(reference, min: type == .relativeChange ? 0 : nil)
        
        let cdfRefernce = calculateCdf(reference, bins: binsRefernce)
        let cdfControl = calculateCdf(control, bins: binsControl)
        
        // Apply
        let binsForecast = binsControl//calculateBins(forecast, min: type == .relativeChange ? 0 : nil)
        let cdfForecast = calculateCdf(forecast, bins: binsForecast)
        let epsilon = forecast.map {
            return interpolate(binsForecast, cdfForecast, x: $0, extrapolate: false)
        }
        let qdm1 = epsilon.map {
            return interpolate(cdfRefernce, binsRefernce, x: $0, extrapolate: false)
        }
        switch type {
        case .absoluteChage:
            return epsilon.enumerated().map { (i, epsilon) in
                return qdm1[i] + forecast[i] - interpolate(cdfControl, binsControl, x: epsilon, extrapolate: false)
            }
        case .relativeChange:
            let maxScaleFactor: Float = 10
            return epsilon.enumerated().map { (i, epsilon) in
                let scale = forecast[i] / interpolate(cdfControl, binsControl, x: epsilon, extrapolate: false)
                return qdm1[i] / min(max(scale, maxScaleFactor * -1), maxScaleFactor)
            }
        }
    }
    
    /// Calcualte min/max from vector and return bins
    /// nQuantiles of 100 should be sufficient
    static func calculateBins(_ vector: ArraySlice<Float>, nQuantiles: Int = 100, min: Float? = nil) -> Bins {
        guard let minMax = vector.minAndMax() else {
            return Bins(min: .nan, max: .nan, nQuantiles: nQuantiles)
        }
        return Bins(min: min ?? minMax.min, max: minMax.max, nQuantiles: nQuantiles)
    }
    
    /// Calculate sumulative distribution function. First value is always 0.
    static func calculateCdf(_ vector: ArraySlice<Float>, bins: Bins) -> [Float] {
        // Technically integer, but uses float for calualtions later
        let count = bins.count
        var cdf = [Float](repeating: 0, count: count)
        for value in vector {
            for (i, bin) in bins.enumerated().reversed() {
                if value < bin || i == count-1 { // Note sure if we need `i == pbf.count-1` -> count all larger than bin.max
                    cdf[i] += 1
                } else {
                    break
                }
            }
        }
        return cdf
    }
    
    /// Find value `x` on first array, then interpolate on the second array to return the value
    static func interpolate<A: RandomAccessCollection<Float>, B: RandomAccessCollection<Float>>(_ xData: A, _ yData: B, x: Float, extrapolate: Bool) -> Float {
        assert(xData.count == yData.count)
        let size = xData.count

        var i = 0;  // find left end of interval for interpolation
        if x >= xData[xData.index(xData.startIndex, offsetBy: size - 2)] {
            i = size - 2;  // special case: beyond right end
        } else {
            while (x > xData[xData.index(xData.startIndex, offsetBy: i + 1)]) { i += 1 }
        }
        let xL = xData[xData.index(xData.startIndex, offsetBy: i)]
        var yL = yData[yData.index(yData.startIndex, offsetBy: i)]
        let xR = xData[xData.index(xData.startIndex, offsetBy: i + 1)]
        var yR = yData[yData.index(yData.startIndex, offsetBy: i + 1)] // points on either side (unless beyond ends)

        if !extrapolate {  // if beyond ends of array and not extrapolating
            if (x < xL) { yR = yL }
            if (x > xR) { yL = yR }
        }
        let dydx = xR - xL == 0 ? 0 : (yR - yL) / (xR - xL);  // gradient
        return yL + dydx * (x - xL);       // linear interpolation
    }
}


/// Represent bin sizes. Iteratable like an array, but only stores min/max/nQuantiles
struct Bins {
    let min: Float
    let max: Float
    let nQuantiles: Int
}

extension Bins: RandomAccessCollection {
    subscript(position: Int) -> Float {
        get {
            return min + (max - min) / Float(nQuantiles) * Float(position)
        }
    }
    
    var indices: Range<Int> {
        return startIndex..<endIndex
    }
    
    var startIndex: Int {
        return 0
    }
    
    var endIndex: Int {
        return nQuantiles
    }
    
    func index(before i: Int) -> Int {
        i - 1
    }
    
    func index(after i: Int) -> Int {
        i + 1
    }
}