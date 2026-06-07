//
//  AnnotationController.swift
//  apple_maps_flutter
//
//  Created by Luis Thein on 09.09.19.
//

import Foundation
import MapKit

extension AppleMapController: AnnotationDelegate {

    public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView)  {
        if let annotation: FlutterAnnotation = view.annotation as? FlutterAnnotation  {
            
            // Si acabamos de levantar el dedo de mantener pulsado este pin, ignoramos la selección normal
            if let lastId = AppleMapController.lastLongPressedAnnotationId,
               lastId == annotation.id,
               Date().timeIntervalSince(AppleMapController.lastLongPressTime) < 0.5 {
                
                mapView.deselectAnnotation(annotation, animated: false)
                AppleMapController.lastLongPressedAnnotationId = nil
                return
            }
            
            self.currentlySelectedAnnotation = annotation.id
            if !annotation.selectedProgrammatically {
                self.onAnnotationClick(annotation: annotation)
                
                // SOLUCIÓN 1: Movemos esto a un hilo asíncrono para que no bloquee el renderizado de selección
                DispatchQueue.main.async {
                    if !self.isAnnotationInFront(zIndex: annotation.zIndex) {
                        self.moveToFront(annotation: annotation)
                    }
                }
            } else {
                annotation.selectedProgrammatically = false
            }

            if annotation.infoWindowConsumesTapEvents {
                // SOLUCIÓN 2: Solo añadimos el gesto si NO lo tiene ya
                let hasTap = view.gestureRecognizers?.contains(where: { $0 is InfoWindowTapGestureRecognizer }) ?? false
                if !hasTap {
                    let tapGestureRecognizer = InfoWindowTapGestureRecognizer(target: self, action: #selector(onCalloutTapped))
                    tapGestureRecognizer.annotationId = annotation.id
                    view.addGestureRecognizer(tapGestureRecognizer)
                } else {
                    // Si ya lo tiene, solo actualizamos el ID por si la vista fue reciclada
                    if let existingTap = view.gestureRecognizers?.first(where: { $0 is InfoWindowTapGestureRecognizer }) as? InfoWindowTapGestureRecognizer {
                        existingTap.annotationId = annotation.id
                    }
                }
            }
        }
    }
    
    public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is MKUserLocation {
            return nil
        } else if let flutterAnnotation = annotation as? FlutterAnnotation {
            return self.getAnnotationView(annotation: flutterAnnotation)
        }
        return nil
    }
    
    public func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
        if let annotation: FlutterAnnotation = view.annotation as? FlutterAnnotation {
            self.onAnnotationDrag(annotation: annotation, newState: newState)
        }
    }
    
    func annotationsToAdd(annotations: NSArray) {
        for annotation in annotations {
            let annotationData: Dictionary<String, Any> = annotation as! Dictionary<String, Any>
            self.addAnnotation(annotationData: annotationData)
        }
    }
    
    func annotationsToChange(annotations: NSArray) {
        let oldAnnotations: [MKAnnotation] = self.mapView.annotations
        for annotation in annotations {
            let annotationData: Dictionary<String, Any> = annotation as! Dictionary<String, Any>
            if let annotationToChange = oldAnnotations.filter({($0 as? FlutterAnnotation)?.id == annotationData["annotationId"] as? String}).first as? FlutterAnnotation {
                let newAnnotation = FlutterAnnotation.init(fromDictionary: annotationData, registrar: registrar)
                if annotationToChange != newAnnotation {
                    if !annotationToChange.wasDragged {
                        updateAnnotation(annotation: newAnnotation)
                    } else {
                        annotationToChange.wasDragged = false
                    }
                }
            }
        }
    }
    
    func annotationsIdsToRemove(annotationIds: NSArray) {
        for annotationId in annotationIds {
            if let annotationIdString: String = annotationId as? String {
                self.removeAnnotation(id: annotationIdString)
            }
        }
    }
    
    func onAnnotationClick(annotation: MKAnnotation) {
        if let flutterAnnotation: FlutterAnnotation = annotation as? FlutterAnnotation {
            self.channel.invokeMethod("annotation#onTap", arguments: ["annotationId": flutterAnnotation.id])
        }
    }
    
    @objc func onAnnotationLongPressed(longPress: AnnotationLongPressGestureRecognizer) {
        if let annotationId = longPress.annotationId {
            if longPress.state == .began {
                // El usuario empieza a mantener pulsado el pin
                AppleMapController.lastLongPressedAnnotationId = annotationId
                AppleMapController.lastLongPressTime = Date()
                self.channel.invokeMethod("annotation#onLongPress", arguments: ["annotationId": annotationId])
            } else if longPress.state == .ended || longPress.state == .cancelled || longPress.state == .failed {
                // Actualizamos el tiempo cuando el usuario levanta el dedo
                // para que el didSelect nativo que ocurre inmediatamente después sea ignorado correctamente.
                AppleMapController.lastLongPressTime = Date()
            }
        }
    }
    
    @objc func onCalloutTapped(sender: InfoWindowTapGestureRecognizer) {
        if let annotationId: String = sender.annotationId {
            self.channel.invokeMethod("infoWindow#onTap", arguments: ["annotationId": annotationId])
        }
    }
    
    private func onAnnotationDrag(annotation: FlutterAnnotation, newState: MKAnnotationView.DragState) {
        if newState == .starting {
            self.channel.invokeMethod("annotation#onDragStart", arguments: ["annotationId": annotation.id, "position": [annotation.coordinate.latitude, annotation.coordinate.longitude]])
        } else if newState == .dragging {
            self.channel.invokeMethod("annotation#onDrag", arguments: ["annotationId": annotation.id, "position": [annotation.coordinate.latitude, annotation.coordinate.longitude]])
        } else if newState == .ending {
            self.channel.invokeMethod("annotation#onDragEnd", arguments: ["annotationId": annotation.id, "position": [annotation.coordinate.latitude, annotation.coordinate.longitude]])
        }
    }
    
    private func addAnnotation(annotationData: Dictionary<String, Any>) {
        let annotation: FlutterAnnotation = FlutterAnnotation.init(fromDictionary: annotationData, registrar: registrar)
        self.mapView.addAnnotation(annotation)
    }
    
    private func updateAnnotation(annotation: FlutterAnnotation) {
        if let oldAnnotation = self.getAnnotation(with: annotation.id) {
            let oldIconType = oldAnnotation.icon.iconType
            let iconChanged = oldAnnotation.icon != annotation.icon
            
            UIView.animate(withDuration: 0.32, animations: {
                oldAnnotation.coordinate = annotation.coordinate
                oldAnnotation.zIndex = annotation.zIndex
                oldAnnotation.anchor = annotation.anchor
                oldAnnotation.alpha = annotation.alpha
                oldAnnotation.isVisible = annotation.isVisible
                oldAnnotation.title = annotation.title
                oldAnnotation.subtitle = annotation.subtitle
                oldAnnotation.icon = annotation.icon
            })
            
            if oldIconType != annotation.icon.iconType {
                self.mapView.removeAnnotation(oldAnnotation)
                self.mapView.addAnnotation(oldAnnotation)
            } else {
                if let view = self.mapView.view(for: oldAnnotation) {
                    if #available(iOS 11.0, *), annotation.icon.iconType == IconType.MARKER {
                        if let markerView = view as? FlutterMarkerAnnotationView, let hueColor = annotation.icon.hueColor {
                            markerView.markerTintColor = UIColor(hue: CGFloat(hueColor), saturation: 1, brightness: 1, alpha: 1)
                        }
                    } else if annotation.icon.iconType == .CUSTOM_FROM_ASSET || annotation.icon.iconType == .CUSTOM_FROM_BYTES {
                        if let customView = view as? FlutterAnnotationView {
                            if iconChanged {
                                // SOLUCIÓN 3: Hilo asíncrono para forzar el repintado de la nueva imagen
                                DispatchQueue.main.async {
                                    customView.image = annotation.icon.image
                                    customView.layer.contents = annotation.icon.image?.cgImage
                                    customView.setNeedsLayout()
                                    customView.setNeedsDisplay()
                                    customView.layer.setNeedsDisplay()
                                }
                            } else {
                                customView.image = annotation.icon.image
                            }
                        }
                    } else {
                        if let pinView = view as? MKPinAnnotationView, let hueColor = annotation.icon.hueColor {
                            pinView.pinTintColor = UIColor(hue: CGFloat(hueColor), saturation: 1, brightness: 1, alpha: 1)
                        }
                    }
                }
            }
        }
    }
    
    func removeAllAnnotations() {
        self.mapView.removeAnnotations(self.mapView.annotations)
    }
    
    func selectAnnotation(with id: String) {
        if let annotation: FlutterAnnotation = self.getAnnotation(with: id) {
            annotation.selectedProgrammatically = true
            self.mapView.selectAnnotation(annotation, animated: true)
        }
    }
    
    func hideAnnotation(with id: String) {
        if let annotation: FlutterAnnotation = self.getAnnotation(with: id) {
            self.mapView.deselectAnnotation(annotation, animated: true)
        }
    }
    
    func isAnnotationSelected(with id: String) -> Bool {
        return self.mapView.selectedAnnotations.contains(where: { annotation in return self.getAnnotation(with: id) == (annotation as? FlutterAnnotation)})
    }
    
    private func removeAnnotation(id: String) {
        if let annotation: FlutterAnnotation = self.getAnnotation(with: id) {
            self.mapView.removeAnnotation(annotation)
        }
    }
    
    private func getAnnotation(with id: String) -> FlutterAnnotation? {
        let flutterAnnotations: [FlutterAnnotation] = self.mapView.annotations.compactMap({ $0 as? FlutterAnnotation })
        return flutterAnnotations.filter({ $0.id == id }).first
    }
    
    private func moveToFront(annotation: FlutterAnnotation) {
        let flutterAnnotations: [FlutterAnnotation] = self.mapView.annotations.compactMap({ $0 as? FlutterAnnotation })
        for flutterAnnotation in flutterAnnotations {
            if flutterAnnotation.zIndex >= annotation.zIndex {
                flutterAnnotation.zIndex = flutterAnnotation.zIndex - 1
            }
        }
        annotation.zIndex = Double(flutterAnnotations.count)
        self.updateAnnotation(annotation: annotation)
    }
    
    private func isAnnotationInFront(zIndex: Double) -> Bool {
        let flutterAnnotations: [FlutterAnnotation] = self.mapView.annotations.compactMap({ $0 as? FlutterAnnotation })
        var isInFront: Bool = true
        for flutterAnnotation in flutterAnnotations {
            if flutterAnnotation.zIndex > zIndex {
                isInFront = false
                break
            }
        }
        return isInFront
    }
    
    public func getAnnotationView(annotation: FlutterAnnotation) -> MKAnnotationView {
        let identifier: String = annotation.icon.iconType.identifier
        var annotationView = self.mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
        let oldAnnotation = annotationView?.annotation as? FlutterAnnotation
        
        if annotationView == nil || oldAnnotation?.icon.iconType != annotation.icon.iconType {
            if #available(iOS 11.0, *), annotation.icon.iconType == IconType.MARKER {
                annotationView = FlutterMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            } else if annotation.icon.iconType == .CUSTOM_FROM_ASSET || annotation.icon.iconType == .CUSTOM_FROM_BYTES {
                annotationView = FlutterAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                annotationView?.image = annotation.icon.image
            } else {
                annotationView = MKPinAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            }
        } else {
            annotationView!.annotation = annotation
        }
        
        if #available(iOS 11.0, *), annotation.icon.iconType == IconType.MARKER {
            if let markerView = annotationView as? FlutterMarkerAnnotationView, let hueColor = annotation.icon.hueColor {
                markerView.markerTintColor = UIColor(hue: CGFloat(hueColor), saturation: 1, brightness: 1, alpha: 1)
            }
        } else if annotation.icon.iconType == .CUSTOM_FROM_ASSET || annotation.icon.iconType == .CUSTOM_FROM_BYTES {
            if let customView = annotationView as? FlutterAnnotationView {
                customView.image = annotation.icon.image
            }
        } else {
            if let pinView = annotationView as? MKPinAnnotationView, let hueColor = annotation.icon.hueColor {
                pinView.pinTintColor = UIColor(hue: CGFloat(hueColor), saturation: 1, brightness: 1, alpha: 1)
            }
        }
        
        annotationView!.alpha = CGFloat(annotation.alpha ?? 1.0)
        annotationView!.isDraggable = annotation.isDraggable ?? false
        annotationView!.canShowCallout = annotation.infoWindowConsumesTapEvents || annotation.title != nil || annotation.subtitle != nil
        annotationView!.centerOffset = CGPoint(x: annotation.anchor.x, y: annotation.anchor.y)
        annotationView!.calloutOffset = CGPoint(x: annotation.calloutOffset.x, y: annotation.calloutOffset.y)
        annotationView!.isHidden = !(annotation.isVisible ?? true)
        
        if var customView = annotationView as? ZPositionableAnnotation {
            customView.stickyZPosition = CGFloat(annotation.zIndex)
        }
        
        // SOLUCIÓN 4: Evitar duplicados de LongPressGestures para no romper el Selection Mode
        var hasLongPress = false
        if let recognizers = annotationView!.gestureRecognizers {
            for recognizer in recognizers {
                if let longPress = recognizer as? AnnotationLongPressGestureRecognizer {
                    longPress.annotationId = annotation.id // Actualizamos ID
                    hasLongPress = true
                }
            }
        }
        
        if !hasLongPress {
            let longPressGestureRecognizer = AnnotationLongPressGestureRecognizer(target: self, action: #selector(onAnnotationLongPressed))
            longPressGestureRecognizer.annotationId = annotation.id
            annotationView!.addGestureRecognizer(longPressGestureRecognizer)
        }
        
        return annotationView!
    }
}

class InfoWindowTapGestureRecognizer: UITapGestureRecognizer {
    var annotationId: String?
}

class AnnotationLongPressGestureRecognizer: UILongPressGestureRecognizer, UIGestureRecognizerDelegate {
    var annotationId: String?
    
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        self.delegate = self
        self.cancelsTouchesInView = false
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

extension IconType {
    var identifier: String {
        switch self {
        case .PIN:
            return "PinAnnotationView"
        case .MARKER:
            return "MarkerAnnotationView"
        case .CUSTOM_FROM_ASSET:
            return "CustomAnnotationView"
        case .CUSTOM_FROM_BYTES:
            return "CustomAnnotationView"
        }
    }
}
