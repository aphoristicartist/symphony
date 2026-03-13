import gleam/option.{type Option}

/// Raw Plane work item from the API
pub type PlaneWorkItem {
  PlaneWorkItem(
    id: String,
    sequence_id: Int,
    project_identifier: String,
    name: String,
    description_html: Option(String),
    priority: Option(String),
    state_detail: PlaneStateDetail,
    created_at: String,
    updated_at: String,
    label_details: List(PlaneLabel),
  )
}

pub type PlaneStateDetail {
  PlaneStateDetail(id: String, name: String, group: String)
}

pub type PlaneLabel {
  PlaneLabel(id: String, name: String)
}

pub type PlaneComment {
  PlaneComment(
    id: String,
    comment_html: String,
    actor_detail: Option(String),
    created_at: String,
  )
}
