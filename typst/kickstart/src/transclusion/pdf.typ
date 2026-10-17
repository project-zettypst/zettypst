#import "instance.typ": consumer, instantiate, labels

#let instances = counter("zettypst.pdf.instance")
#let consume = consumer("zettyp-pdf-", instances, "PDF")

#let view(note, instance) = {
  if instance.heading-renderer == none {
    heading(level: instance.level, instance.title)
  } else { (instance.heading-renderer)(instance.title, instance.level) }
  instance.body
}
